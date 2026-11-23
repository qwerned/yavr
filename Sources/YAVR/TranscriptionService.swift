import FluidAudio
import Foundation
import YAVRCore

/// Загрузка моделей и пайплайн распознавания: ASR -> boosting -> замены.
actor TranscriptionService {
    static let shared = TranscriptionService()

    private var asrManager: AsrManager?
    private var ctcModels: CtcModels?

    private var whisper: WhisperEngine?

    /// Готовность выбранного движка (для Whisper — модель и Silero VAD).
    nonisolated static func modelsInstalled(model: RecognitionModel = Prefs.recognitionModel) -> Bool {
        if model == .whisperTurbo { return WhisperEngine.isInstalled }
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory())
            && CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory())
    }

    /// Скачивает выбранную модель и необходимые ей ресурсы.
    func downloadModels(
        model: RecognitionModel = Prefs.recognitionModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if model == .whisperTurbo {
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
    /// assert в глобальных деструкторах, если модель ещё загружена.
    func unloadWhisper() {
        whisper = nil
    }

    private func loadWhisper() async throws -> WhisperEngine {
        guard Self.modelsInstalled(model: .whisperTurbo) else { throw DictationError.modelNotInstalled }
        asrManager = nil
        ctcModels = nil
        if let whisper { return whisper }
        let engine = try await WhisperEngine()
        whisper = engine
        return engine
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
            let text = try await whisper.transcribe(
                samples, languageCode: languageCode, vocabulary: vocabulary)
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
