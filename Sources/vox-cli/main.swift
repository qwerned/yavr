import AVFoundation
import FluidAudio
import Foundation
import VoxCore

// Этап 1: CLI-прототип. Аудиофайл или микрофон -> Parakeet TDT v3 (русский) -> текст.
// Boosting: отдельный проход CTC keyword spotter + vocabulary rescorer поверх результата.
//
// Использование:
//   vox-cli <audio.wav|m4a> [--no-boost | --boosted] [--glossary <path.json>] [-v]
//   vox-cli --mic ...   — запись с микрофона, Enter = стоп
// По умолчанию печатает оба варианта: no boost и boosted.

func log(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

func fail(_ message: String) -> Never {
    log("error: " + message)
    exit(1)
}

// --- Разбор аргументов ---

enum OutputMode {
    case compare  // оба варианта (дефолт)
    case plainOnly  // только без бустинга
    case boostedOnly  // только с бустингом
}

var mode: OutputMode = .compare
var verbose = false
var useMic = false
var glossaryPath: String? = nil
var audioPath: String? = nil
var savePath: String? = nil

var argsIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argsIterator.next() {
    switch arg {
    case "--no-boost": mode = .plainOnly
    case "--boosted": mode = .boostedOnly
    case "--compare": mode = .compare
    case "--mic": useMic = true
    case "--save":
        guard let path = argsIterator.next() else { fail("--save requires a path") }
        savePath = path
    case "-v", "--verbose": verbose = true
    case "--glossary":
        guard let path = argsIterator.next() else { fail("--glossary requires a path") }
        glossaryPath = path
    default:
        audioPath = arg
    }
}

if !useMic {
    guard let audioPath else {
        print("usage: vox-cli <audio.wav|m4a> [--no-boost | --boosted] [--glossary <path.json>] [-v]")
        print("       vox-cli --mic [--no-boost | --boosted] [--glossary <path.json>] [-v]")
        exit(64)
    }
    guard FileManager.default.fileExists(atPath: audioPath) else {
        fail("file not found: \(audioPath)")
    }
}

/// Запись с микрофона до нажатия Enter; отдаёт 16 kHz mono Float32.
func recordFromMicrophone() throws -> [Float] {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.inputFormat(forBus: 0)
    guard format.sampleRate > 0 else {
        fail("no input device (microphone permission denied or no mic)")
    }

    let converter = AudioConverter()
    let collector = SampleCollector()

    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        if let samples = try? converter.resampleBuffer(buffer) {
            collector.append(samples)
        }
    }

    engine.prepare()
    try engine.start()
    log("recording... press Enter to stop")
    _ = readLine()
    engine.stop()
    input.removeTap(onBus: 0)
    return collector.drain()
}

/// Потокобезопасный накопитель сэмплов из аудио-колбэка.
final class SampleCollector: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    func append(_ newSamples: [Float]) {
        lock.lock()
        samples.append(contentsOf: newSamples)
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

// Дефолтный глоссарий лежит рядом с корнем проекта; для прототипа ищем
// сначала явный путь, потом glossary.json в текущей директории.
let resolvedGlossaryPath: String = {
    if let glossaryPath { return glossaryPath }
    let cwdGlossary = FileManager.default.currentDirectoryPath + "/glossary.json"
    return cwdGlossary
}()

// --- Пайплайн ---

/// Boosting-проход: CTC keyword spotting + rescoring распознанного текста.
@MainActor
func applyBoosting(
    to result: ASRResult,
    samples: [Float],
    glossaryFile: String
) async throws -> ASRResult {
    guard FileManager.default.fileExists(atPath: glossaryFile) else {
        fail("glossary not found: \(glossaryFile)")
    }

    // Загружает словарь и CTC-модели (первый запуск скачает ctc110m с HuggingFace)
    let (customVocab, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(from: glossaryFile)
    if verbose { log("glossary: \(customVocab.terms.count) terms") }

    let blankId = ctcModels.vocabulary.count
    let spotter = CtcKeywordSpotter(models: ctcModels, blankId: blankId)

    let spotResult = try await spotter.spotKeywordsWithLogProbs(
        audioSamples: samples,
        customVocabulary: customVocab,
        minScore: nil
    )

    guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty, !spotResult.logProbs.isEmpty else {
        if verbose { log("boosting skipped: no token timings or logprobs") }
        return result
    }

    let vocabConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: customVocab.terms.count)
    let rescorer = try await VocabularyRescorer.create(
        spotter: spotter,
        vocabulary: customVocab,
        config: .default,
        ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctcModels.variant)
    )

    let rescoreOutput = rescorer.ctcTokenRescore(
        transcript: result.text,
        tokenTimings: tokenTimings,
        logProbs: spotResult.logProbs,
        frameDuration: spotResult.frameDuration,
        cbw: vocabConfig.cbw,
        marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
        minSimilarity: vocabConfig.minSimilarity
    )

    if rescoreOutput.wasModified {
        if verbose {
            for replacement in rescoreOutput.replacements where replacement.shouldReplace {
                log("  '\(replacement.originalWord)' -> '\(replacement.replacementWord ?? "")'")
            }
        }
        // rescoreOutput.text пересобран из слов и теряет пунктуацию,
        // поэтому применяем замены к исходному тексту сами.
        return ASRResult(
            text: applyReplacements(rescoreOutput.replacements, to: result.text),
            confidence: result.confidence,
            duration: result.duration,
            processingTime: result.processingTime,
            tokenTimings: result.tokenTimings
        )
    }
    return result
}

/// Применяет замены рескорера к исходному тексту, сохраняя пунктуацию
/// по краям заменяемого слова («айрфлоу.» -> «Airflow.»).
func applyReplacements(
    _ replacements: [VocabularyRescorer.RescoringResult],
    to transcript: String
) -> String {
    var text = transcript
    // Длинные оригиналы первыми, чтобы «мердж реквест» не разъедало по частям
    let applicable = replacements
        .filter { $0.shouldReplace && $0.replacementWord != nil }
        .sorted { $0.originalWord.count > $1.originalWord.count }
    for replacement in applicable {
        let original = replacement.originalWord
        guard let range = text.range(of: original) else { continue }
        let leading = String(original.prefix(while: { !$0.isLetter && !$0.isNumber }))
        let trailing = String(
            original.reversed().prefix(while: { !$0.isLetter && !$0.isNumber }).reversed())
        text.replaceSubrange(range, with: leading + replacement.replacementWord! + trailing)
    }
    return text
}

do {
    let modelDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml",
            isDirectory: true)

    let models: AsrModels
    if AsrModels.modelsExist(at: modelDir) {
        if verbose { log("loading local model: \(modelDir.path)") }
        models = try await AsrModels.load(from: modelDir)
    } else {
        log("local model not found, downloading to \(modelDir.path)...")
        models = try await AsrModels.downloadAndLoad()
    }

    let asrManager = AsrManager(config: .default)
    try await asrManager.loadModels(models)

    let samples: [Float]
    if useMic {
        samples = try recordFromMicrophone()
        guard samples.count > 8000 else { fail("recording too short (\(samples.count) samples)") }
    } else {
        samples = try AudioConverter().resampleAudioFile(path: audioPath!)
    }

    // Сохранение WAV 16kHz mono — для сравнения с другими движками
    if let savePath {
        let url = URL(fileURLWithPath: savePath)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData!.pointee.update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
        log("saved: \(savePath)")
    }
    if verbose {
        log("audio: \(samples.count) samples @16kHz (\(String(format: "%.1f", Double(samples.count) / 16000.0))s)")
    }

    var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
    let plain = try await asrManager.transcribe(samples, decoderState: &decoderState, language: .russian)

    // Этап 2: детерминированные замены поверх бустинга
    let glossary = try Glossary.load(from: URL(fileURLWithPath: resolvedGlossaryPath))
    let replacementEngine = ReplacementEngine(glossary: glossary)

    switch mode {
    case .compare:
        print("--- no boost ---")
        print(plain.text)
        let boosted = try await applyBoosting(to: plain, samples: samples, glossaryFile: resolvedGlossaryPath)
        print("--- boosted ---")
        print(boosted.text)
        print("--- final (boosted + replacements) ---")
        print(replacementEngine.apply(to: boosted.text))
    case .plainOnly:
        print(plain.text)
    case .boostedOnly:
        let boosted = try await applyBoosting(to: plain, samples: samples, glossaryFile: resolvedGlossaryPath)
        print(replacementEngine.apply(to: boosted.text))
    }
} catch {
    fail("\(error)")
}
