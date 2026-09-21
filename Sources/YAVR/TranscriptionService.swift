import FluidAudio
import Foundation
import YAVRCore
import WhisperKit

/// Загрузка моделей и пайплайн распознавания: ASR -> boosting -> замены.
actor TranscriptionService {
    static let shared = TranscriptionService()

    private var asrManager: AsrManager?
    private var ctcModels: CtcModels?

    private var whisper: WhisperKit?
    private static let whisperVariant = "openai_whisper-large-v3-v20240930_626MB"
    private static var whisperCache: URL {
        AppPaths.supportDirectory.appendingPathComponent("WhisperKit", isDirectory: true)
    }
    private static var whisperFolder: URL {
        whisperCache.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(whisperVariant)")
    }
    private static var whisperReadyMarker: URL {
        whisperFolder.appendingPathComponent(".yavr-ready")
    }

    /// Готовность выбранного движка (включая токенизатор для Whisper).
    nonisolated static func modelsInstalled(model: RecognitionModel = Prefs.recognitionModel) -> Bool {
        if model == .whisperTurbo {
            return FileManager.default.fileExists(atPath: whisperReadyMarker.path)
                && ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
                    FileManager.default.fileExists(atPath: whisperFolder.appendingPathComponent($0).path)
                }
        }
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory())
            && CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory())
    }

    /// Скачивает выбранную модель и необходимые ей ресурсы.
    func downloadModels(
        model: RecognitionModel = Prefs.recognitionModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if model == .whisperTurbo {
            let folder = try await WhisperKit.download(
                variant: Self.whisperVariant, downloadBase: Self.whisperCache,
                progressCallback: { progress($0.fractionCompleted * 0.95) })
            // Loading also downloads the tokenizer. Mark ready only after both succeed.
            _ = try await WhisperKit(WhisperKitConfig(
                modelFolder: folder.path, tokenizerFolder: Self.whisperCache,
                verbose: false, prewarm: false, load: true, download: false))
            try Data().write(to: Self.whisperReadyMarker, options: .atomic)
            progress(1)
            return
        }
        _ = try await AsrModels.downloadAndLoad(progressHandler: { p in
            progress(p.fractionCompleted * 0.82)
        })
        _ = try await CtcModels.downloadAndLoad()
        progress(1.0)
    }

    /// Ленивая инициализация менеджеров из кэша моделей.
    private func ensureLoaded(useDictionary: Bool) async throws {
        whisper = nil
        if asrManager == nil {
            guard Self.modelsInstalled(model: .parakeet) else { throw DictationError.modelNotInstalled }
            let models = try await AsrModels.downloadAndLoad()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asrManager = manager
        }
        if useDictionary && ctcModels == nil {
            ctcModels = try await CtcModels.downloadAndLoad()
        }
    }

    /// Полный пайплайн: сэмплы 16 kHz -> текст с терминами.
    func transcribe(
        samples: [Float], glossaryURL: URL, engine: ReplacementEngine, languageCode: String,
        model: RecognitionModel = Prefs.recognitionModel, useDictionary: Bool = Prefs.useDictionary
    ) async throws -> String {
        guard samples.count > 8000 else { throw DictationError.recordingTooShort }
        if model == .whisperTurbo {
            guard Self.modelsInstalled(model: model) else { throw DictationError.modelNotInstalled }
            asrManager = nil
            ctcModels = nil
            if whisper == nil {
                whisper = try await WhisperKit(WhisperKitConfig(
                    modelFolder: Self.whisperFolder.path, tokenizerFolder: Self.whisperCache,
                    verbose: false, prewarm: false, load: true, download: false))
            }
            guard let whisper else { throw DictationError.modelNotInstalled }
            let results = try await whisper.transcribe(
                audioArray: samples,
                decodeOptions: DecodingOptions(
                    language: languageCode == "auto" ? nil : languageCode,
                    detectLanguage: languageCode == "auto", skipSpecialTokens: true))
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return useDictionary ? engine.apply(to: text) : text
        }
        try await ensureLoaded(useDictionary: useDictionary)
        guard let asrManager else { throw DictationError.modelNotInstalled }

        let language = Language(rawValue: languageCode) ?? .russian
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let plain = try await asrManager.transcribe(
            samples, decoderState: &decoderState, language: language)

        guard useDictionary else { return plain.text }
        guard let ctcModels else { return engine.apply(to: plain.text) }
        let boostedText = await boost(
            result: plain, samples: samples, glossaryURL: glossaryURL, ctcModels: ctcModels)

        return engine.apply(to: boostedText)
    }

    /// Boosting-проход; при любом сбое тихо возвращает небустованный текст —
    /// лучше текст без терминов, чем ошибка всей диктовки.
    private func boost(
        result: ASRResult, samples: [Float], glossaryURL: URL, ctcModels: CtcModels
    ) async -> String {
        do {
            guard let (customVocab, models) = try await AcousticVocabulary.withFile(from: glossaryURL, operation: {
                try await CustomVocabularyContext.loadWithCtcTokens(from: $0.path)
            }) else { return result.text }
            _ = models  // уже загружены, повторный вызов берёт кэш

            let blankId = ctcModels.vocabulary.count
            let spotter = CtcKeywordSpotter(models: ctcModels, blankId: blankId)
            let spotResult = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples, customVocabulary: customVocab, minScore: nil)

            guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty,
                !spotResult.logProbs.isEmpty
            else { return result.text }

            let vocabConfig = ContextBiasingConstants.rescorerConfig(
                forVocabSize: customVocab.terms.count)
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: customVocab,
                config: .default,
                ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctcModels.variant))

            let output = rescorer.ctcTokenRescore(
                transcript: result.text,
                tokenTimings: tokenTimings,
                logProbs: spotResult.logProbs,
                frameDuration: spotResult.frameDuration,
                cbw: vocabConfig.cbw,
                marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                minSimilarity: vocabConfig.minSimilarity)

            guard output.wasModified else { return result.text }
            return AcousticReplacements.apply(to: result.text, rescored: output.text,
                changes: output.replacements.compactMap { item in
                    guard item.shouldReplace, let replacement = item.replacementWord else { return nil }
                    return .init(original: item.originalWord, replacement: replacement)
                })
        } catch {
            return result.text
        }
    }

}
