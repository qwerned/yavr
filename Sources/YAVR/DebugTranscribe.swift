import AVFoundation
import Foundation

/// Отладка без микрофона и интерфейса:
/// `YAVR --transcribe file.wav [--model whisperTurbo|parakeet] [--lang ru|en|auto]`.
/// Тот же пайплайн, что у диктовки: распознавание → паразиты → словарь.
@MainActor
enum DebugTranscribe {
    static func run(arguments: [String]) async throws {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        guard let path = value("--transcribe") else { return }
        Prefs.registerDefaults()
        let model = value("--model").flatMap(RecognitionModel.init(rawValue:)) ?? .whisperTurbo
        let language = value("--lang") ?? "ru"
        let samples = try readMono16k(URL(fileURLWithPath: path))

        GlossaryStore.shared.reload()
        let started = Date()
        let text = try await TranscriptionService.shared.transcribe(
            samples: samples, glossaryURL: GlossaryStore.shared.fileURL,
            engine: GlossaryStore.shared.replacementEngine, languageCode: language,
            model: model, useDictionary: Prefs.useDictionary,
            fillerLanguages: Prefs.removeFillerWords ? (language == "auto" ? ["ru", "en"] : [language]) : nil)
        let audio = Double(samples.count) / 16000
        await TranscriptionService.shared.unloadWhisper()
        print(text)
        fputs(String(format: "[%@] аудио %.1f с, распознавание %.2f с\n",
                     model.rawValue, audio, Date().timeIntervalSince(started)), stderr)
    }

    private static func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16000 / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
