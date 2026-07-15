import FluidAudio
import Foundation
import VoxCore

/// Загрузка моделей и пайплайн распознавания: ASR -> boosting -> замены.
actor TranscriptionService {
    static let shared = TranscriptionService()

    private var asrManager: AsrManager?
    private var ctcModels: CtcModels?

    enum ModelStatus {
        case notInstalled
        case installed
    }

    /// Обе модели на диске? (ASR + словарная CTC)
    nonisolated static func modelsInstalled() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory())
            && CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory())
    }

    /// Скачивает обе модели (кэш проверяется внутри FluidAudio).
    /// Прогресс: ASR ~82% объёма, CTC ~18%.
    func downloadModels(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await AsrModels.downloadAndLoad(progressHandler: { p in
            progress(p.fractionCompleted * 0.82)
        })
        _ = try await CtcModels.downloadAndLoad()
        progress(1.0)
    }

    /// Ленивая инициализация менеджеров из кэша моделей.
    private func ensureLoaded() async throws {
        if asrManager == nil {
            guard Self.modelsInstalled() else { throw VoxError.modelNotInstalled }
            let models = try await AsrModels.downloadAndLoad()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asrManager = manager
        }
        if ctcModels == nil {
            ctcModels = try await CtcModels.downloadAndLoad()
        }
    }

    /// Полный пайплайн: сэмплы 16 kHz -> текст с терминами.
    func transcribe(
        samples: [Float], glossaryURL: URL, engine: ReplacementEngine, languageCode: String
    ) async throws -> String {
        try await ensureLoaded()
        guard let asrManager, let ctcModels else { throw VoxError.modelNotInstalled }
        guard samples.count > 8000 else { throw VoxError.recordingTooShort }

        let language = Language(rawValue: languageCode) ?? .russian
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let plain = try await asrManager.transcribe(
            samples, decoderState: &decoderState, language: language)

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
            let (customVocab, models) = try await CustomVocabularyContext.loadWithCtcTokens(
                from: glossaryURL.path)
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
            return Self.applyReplacements(output.replacements, to: result.text)
        } catch {
            return result.text
        }
    }

    /// Применяет замены рескорера к исходному тексту, сохраняя пунктуацию
    /// (пересобранный rescoreOutput.text её теряет).
    static func applyReplacements(
        _ replacements: [VocabularyRescorer.RescoringResult], to transcript: String
    ) -> String {
        var text = transcript
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
}
