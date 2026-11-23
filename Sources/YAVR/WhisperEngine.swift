import Foundation
import TranscribeCpp
import YAVRCore

/// Whisper large-v3-turbo Q8_0 (GGUF) на transcribe.cpp с Metal и Silero VAD —
/// та же сборка модели и тот же движок, что у Орки.
///
/// Пайплайн: Silero VAD находит речь → тишина между фразами выбрасывается
/// (Whisper на тишине галлюцинирует) → одна прогонка Whisper по речи с
/// языком из настроек и терминами словаря в `vocabulary`.
final class WhisperEngine: @unchecked Sendable {
    static let modelFile = PinnedModelFile(
        repo: "handy-computer/whisper-large-v3-turbo-gguf",
        revision: "5eaf945c7978e564bae5b28a5b1639dd93c2bfb1",
        name: "whisper-large-v3-turbo-Q8_0.gguf",
        size: 886_381_760,
        sha256: "b2e30cc286bc9f3aba4db9099fc7403543497c05ce7100d0d83091ddfd25a183")
    static let vadFile = PinnedModelFile(
        repo: "handy-computer/silero-vad-v6.2-gguf",
        revision: "97bbd75179f535e4708bccdf61e9278b8b60dfc7",
        name: "silero-vad-v6.2-F32.gguf",
        size: 1_241_056,
        sha256: "0d871a800c420fdd5d1b17a3aea4296d1c39608f0ff4a9295eb76457eb1c88e6")

    static var directory: URL {
        AppPaths.supportDirectory.appendingPathComponent("Models/whisper", isDirectory: true)
    }

    /// Старый кэш WhisperKit (CoreML) — больше не используется.
    static var legacyWhisperKitDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent("WhisperKit", isDirectory: true)
    }

    static var isInstalled: Bool {
        ModelDownloader.isInstalled(modelFile, in: directory)
            && ModelDownloader.isInstalled(vadFile, in: directory)
    }

    static func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let total = Double(modelFile.size + vadFile.size)
        try await ModelDownloader.download(vadFile, to: directory) { _ in }
        let vadSize = vadFile.size
        try await ModelDownloader.download(modelFile, to: directory) { done in
            progress(Double(vadSize + done) / total)
        }
        try? FileManager.default.removeItem(at: legacyWhisperKitDirectory)
        progress(1)
    }

    private let model: Model
    private let session: Session
    private let vadModel: Model
    private let vad: VadSession

    /// Загрузка с диска и прогрев Metal-шейдеров на полсекунде тишины,
    /// чтобы первая диктовка не ждала компиляцию.
    init() async throws {
        let dir = Self.directory
        model = try Model(path: dir.appendingPathComponent(Self.modelFile.name).path)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        session = try model.session(
            SessionOptions(nThreads: Int32(min(cores, 8, max(4, cores / 2)))))
        vadModel = try Model(
            path: dir.appendingPathComponent(Self.vadFile.name).path,
            options: ModelOptions(backend: .cpu))
        vad = try vadModel.vadSession(threads: 1)
        _ = try? await session.run([Float](repeating: 0, count: 8000), options: RunOptions(timestamps: .none))
    }

    /// `languageCode` — «ru», «en» или «auto»; `vocabulary` — термины словаря.
    func transcribe(_ samples: [Float], languageCode: String, vocabulary: [String]) async throws -> String {
        let speech = try await speechOnly(samples)
        // Меньше 0,3 с речи — это щелчок или вдох, а не фраза.
        guard speech.count >= 4800 else { return "" }

        let language = languageCode == "auto" ? nil : languageCode
        let supportsVocabulary = model.supports(.vocabulary)
        let options = RunOptions(
            timestamps: .none, language: language,
            vocabulary: supportsVocabulary ? vocabulary : [])
        do {
            // «Продолжение следует...» и прочие титры из субтитров в хвосте.
            return WhisperHallucinations.strip(try await session.run(speech, options: options).text)
        } catch TranscribeError.outputTruncated(_, let partial?),
                TranscribeError.outputRepetition(_, let partial?) {
            // Обрезанный или зациклившийся вывод: целая часть лучше ошибки.
            return partial.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Только речь: отрезки VAD с запасом по краям, склеенные через короткую
    /// паузу. Паузы внутри фразы до 0,6 с остаются — как в Орке.
    private func speechOnly(_ samples: [Float]) async throws -> [Float] {
        let result = try await vad.run(
            samples,
            options: VadOptions(minSpeechMs: 250, minSilenceMs: 600, speechPadMs: 300))
        let gap = [Float](repeating: 0, count: 3200)  // 0,2 с
        var speech: [Float] = []
        speech.reserveCapacity(samples.count)
        for segment in result.segments {
            let start = max(0, Int(segment.startSample))
            let end = min(samples.count, Int(segment.endSample))
            guard end > start else { continue }
            if !speech.isEmpty { speech += gap }
            speech += samples[start..<end]
        }
        return speech
    }
}
