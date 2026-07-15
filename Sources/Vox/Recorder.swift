import AVFoundation
import FluidAudio
import Foundation

/// Запись с микрофона: 16 kHz mono Float32, лимит длительности.
final class Recorder {
    static let maxDuration: TimeInterval = 5 * 60

    private var engine: AVAudioEngine?
    private let converter = AudioConverter()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var limitTimer: Timer?

    /// Вызывается на main при достижении лимита записи.
    var onLimitReached: (() -> Void)?

    var isRecording: Bool { engine != nil }

    func start(microphoneUID: String) throws {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        AudioDevices.setInputDevice(uid: microphoneUID, for: engine)

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw VoxError.noMicrophone
        }

        lock.lock(); samples.removeAll(); lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let converted = try? self.converter.resampleBuffer(buffer) else { return }
            self.lock.lock()
            self.samples.append(contentsOf: converted)
            self.lock.unlock()
        }

        engine.prepare()
        try engine.start()
        self.engine = engine

        limitTimer = Timer.scheduledTimer(withTimeInterval: Self.maxDuration, repeats: false) {
            [weak self] _ in
            self?.onLimitReached?()
        }
    }

    /// Останавливает запись и отдаёт накопленные сэмплы.
    func stop() -> [Float] {
        limitTimer?.invalidate()
        limitTimer = nil
        guard let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        lock.lock()
        defer { samples.removeAll(); lock.unlock() }
        return samples
    }
}

enum VoxError: LocalizedError {
    case noMicrophone
    case modelNotInstalled
    case recordingTooShort
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "Микрофон недоступен — проверьте разрешение в Системных настройках"
        case .modelNotInstalled: return "Модель не установлена — скачайте её в настройках"
        case .recordingTooShort: return "Запись слишком короткая"
        case .transcriptionFailed(let reason): return "Распознавание не удалось: \(reason)"
        }
    }
}
