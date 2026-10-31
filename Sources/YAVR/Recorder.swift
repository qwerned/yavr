import AVFoundation
import FluidAudio
import Foundation
import os.log

private let recLog = Logger(subsystem: "com.yavr", category: "Recorder")

/// Запись с микрофона: 16 kHz mono Float32, лимит длительности.
/// Объект engine переиспользуется между записями — пересоздание
/// AVAudioEngine через раз не получает tap-буферы от CoreAudio. Но между
/// записями engine остановлен, иначе микрофон занят и горит индикатор.
final class Recorder {
    static let maxDuration: TimeInterval = 5 * 60

    private var engine: AVAudioEngine?
    private var converter: AudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var limitTimer: Timer?
    private var recording = false
    /// С каким входом создан engine: выбранный UID или системный по умолчанию.
    private var engineInput = ""

    /// Вызывается на main при достижении лимита записи.
    var onLimitReached: (() -> Void)?

    /// Если задан, каждый буфер конвертируется в PCM Int16 LE и отдаётся сюда
    /// (для стриминга в облачный STT). Сэмплы всё равно копятся в samples.
    var onAudioChunk: ((Data) -> Void)?

    var isRecording: Bool { recording }

    func start(microphoneUID: String) throws {
        guard !recording else { return }

        // Пересоздаём engine, если его нет или сменился вход — в том числе
        // системный (подключили AirPods): старый engine держит прежний формат.
        let wantedInput = microphoneUID.isEmpty
            ? "default:\(AudioDevices.defaultInputDeviceID())" : microphoneUID
        if engine == nil || wantedInput != engineInput {
            if let old = engine {
                old.inputNode.removeTap(onBus: 0)
                old.stop()
            }
            let newEngine = AVAudioEngine()
            AudioDevices.setInputDevice(uid: microphoneUID, for: newEngine)
            engine = newEngine
            converter = AudioConverter()
            engineInput = wantedInput
            recLog.notice("start: created new engine")
        }

        guard let engine else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw DictationError.noMicrophone
        }

        lock.lock(); samples.removeAll(); lock.unlock()

        let hasChunkCallback = onAudioChunk != nil
        recLog.notice("start: installing tap, onAudioChunk=\(hasChunkCallback)")

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let converter = self.converter,
                  let converted = try? converter.resampleBuffer(buffer) else { return }
            self.lock.lock()
            self.samples.append(contentsOf: converted)
            let chunkCallback = self.onAudioChunk
            self.lock.unlock()

            if let chunkCallback {
                let pcm16 = Self.floatToPCM16(converted)
                chunkCallback(pcm16)
            }
        }

        // Запуск после установки tap — тот же порядок, что до переиспользования.
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }
        }

        recording = true
        recLog.notice("start: recording")

        limitTimer = Timer.scheduledTimer(withTimeInterval: Self.maxDuration, repeats: false) {
            [weak self] _ in
            self?.onLimitReached?()
        }
    }

    /// Float32 [-1,1] → Int16 LE Data для WebSocket-стрима.
    private static func floatToPCM16(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { ptr in
            let buf = ptr.bindMemory(to: Int16.self)
            for i in samples.indices {
                let clamped = max(-1, min(1, samples[i]))
                buf[i] = Int16(clamped * 32767)
            }
        }
        return data
    }

    /// Останавливает запись и отдаёт накопленные сэмплы.
    /// Engine останавливается (микрофон освобождается), объект остаётся
    /// для следующей записи.
    func stop() -> [Float] {
        limitTimer?.invalidate()
        limitTimer = nil
        guard let engine, recording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recording = false
        recLog.notice("stop: tap removed, engine stopped")
        lock.lock()
        defer { samples.removeAll(); lock.unlock() }
        return samples
    }
}

enum DictationError: LocalizedError {
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
