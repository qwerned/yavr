import FluidAudio
import Foundation
import YAVRCore

/// Загрузка моделей и пайплайн распознавания: ASR -> boosting -> замены.
actor TranscriptionService {
    static let shared = TranscriptionService()

    private var asrManager: AsrManager?
    private var ctcModels: CtcModels?

    private var whisper: WhisperEngine?
    /// Идущая загрузка Whisper: все вызывающие ждут одну и ту же (актор
    /// реентерабелен, иначе прогрев и первая диктовка загрузили бы две модели).
    private var whisperLoad: Task<WhisperEngine, Error>?
    /// Сколько прогонов Whisper идёт сейчас; выгрузка ждёт, пока станет 0.
    private var whisperRuns = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Готовность выбранного движка (для Whisper — модель и Silero VAD).
    nonisolated static func modelsInstalled(model: RecognitionModel = Prefs.recognitionModel) -> Bool {
        if model == .whisperTurbo { return WhisperEngine.isInstalled }
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory())
            && CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory())
    }

    /// Скачивает выбранную модель и необходимые ей ресурсы.
    /// `force` — «Скачать заново»: установленные файлы удаляются и качаются снова.
    func downloadModels(
        model: RecognitionModel = Prefs.recognitionModel, force: Bool = false,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if model == .whisperTurbo {
            if force {
                await unloadWhisper()
                WhisperEngine.removeFiles()
            }
            try await WhisperEngine.download(progress: progress)
            return
        }
        _ = try await AsrModels.downloadAndLoad(progressHandler: { p in
            progress(p.fractionCompleted * 0.82)
        })
        _ = try await CtcModels.downloadAndLoad()
        progress(1.0)
    }

    /// Загружает Whisper заранее (при запуске), чтобы первая диктовка не ждала.
    func prewarm(model: RecognitionModel = Prefs.recognitionModel) async {
        guard model == .whisperTurbo, Self.modelsInstalled(model: model) else { return }
        _ = try? await loadWhisper()
    }

    /// Освобождает Whisper до выхода из процесса: ggml-metal падает на
    /// assert в глобальных деструкторах, если модель ещё загружена. Ждёт
    /// идущую загрузку и прогоны (отменённый прогон прерывается быстро).
    func unloadWhisper() async {
        _ = try? await whisperLoad?.value
        while whisperRuns > 0 {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        whisper = nil
    }

    private func loadWhisper() async throws -> WhisperEngine {
        guard Self.modelsInstalled(model: .whisperTurbo) else { throw DictationError.modelNotInstalled }
        asrManager = nil
        ctcModels = nil
        if let whisper { return whisper }
        if let whisperLoad { return try await whisperLoad.value }
        let load = Task { try await WhisperEngine() }
        whisperLoad = load
        defer { whisperLoad = nil }
        let engine = try await load.value
        whisper = engine
        return engine
    }

    private func runWhisper<T>(_ body: () async throws -> T) async rethrows -> T {
        whisperRuns += 1
        defer {
            whisperRuns -= 1
            if whisperRuns == 0 {
                idleWaiters.forEach { $0.resume() }
                idleWaiters.removeAll()
            }
        }
        return try await body()
    }

    /// Канонические написания терминов словаря, без повторов.
    private static func vocabulary(from glossaryURL: URL) -> [String] {
        guard let glossary = try? Glossary.load(from: glossaryURL) else { return [] }
        var seen = Set<String>()
        return glossary.terms.map(\.text).filter { seen.insert($0.lowercased()).inserted }
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
        model: RecognitionModel = Prefs.recognitionModel, useDictionary: Bool = Prefs.useDictionary,
        fillerLanguages: [String]? = Prefs.fillerLanguages
    ) async throws -> String {
        /// Распознавание → удаление паразитов → словарь.
        func finalize(_ text: String) -> String {
            let cleaned = fillerLanguages.map { FillerWords.remove(from: text, languages: $0) } ?? text
            return useDictionary ? engine.apply(to: cleaned) : cleaned
        }
        guard samples.count > 8000 else { throw DictationError.recordingTooShort }
        if model == .whisperTurbo {
            let whisper = try await loadWhisper()
            // Термины словаря — подсказка самому Whisper, а не только замены после.
            let vocabulary = useDictionary ? Self.vocabulary(from: glossaryURL) : []
            let text = try await runWhisper {
                try await whisper.transcribe(samples, languageCode: languageCode, vocabulary: vocabulary)
            }
            return finalize(text)
        }
        try await ensureLoaded(useDictionary: useDictionary)
        guard let asrManager else { throw DictationError.modelNotInstalled }

        let language = Language(rawValue: languageCode) ?? .russian
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let plain = try await asrManager.transcribe(
            samples, decoderState: &decoderState, language: language)

        guard useDictionary, let ctcModels else { return finalize(plain.text) }
        let boostedText = await boost(
            result: plain, samples: samples, glossaryURL: glossaryURL, ctcModels: ctcModels)

        return finalize(boostedText)
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
