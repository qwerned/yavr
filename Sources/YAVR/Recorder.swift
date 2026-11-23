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

    /// Уровень громкости для индикатора: level 0…1 и флаг клиппинга.
    /// Вызывается на main не чаще ~30 раз в секунду.
    var onLevel: ((_ level: Float, _ clipping: Bool) -> Void)?

    /// Состояние измерителя; меняется только в потоке tap.
    private var meter = LevelMeter()

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
        meter = LevelMeter()

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

            if let reading = self.meter.process(converted) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.recording else { return }
                    self.onLevel?(reading.level, reading.clipping)
                }
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

/// Сглаженный уровень речи над шумом: быстро растёт, медленно спадает.
/// Клиппинг держится 500 мс, чтобы индикатор успел покраснеть.
private struct LevelMeter {
    private var noiseFloor: Float = 0.008
    private var smoothed: Float = 0
    private var clipUntil: Date = .distantPast
    private var lastEmit: Date = .distantPast

    mutating func process(_ buffer: [Float]) -> (level: Float, clipping: Bool)? {
        guard !buffer.isEmpty else { return nil }
        var sum: Float = 0
        var peak: Float = 0
        for x in buffer {
            sum += x * x
            peak = max(peak, abs(x))
        }
        let rms = (sum / Float(buffer.count)).squareRoot()

        noiseFloor = max(0.004, noiseFloor * 0.96 + min(rms, noiseFloor * 2) * 0.04)
        let target = min(max((rms - noiseFloor) / 0.16, 0), 1)
        let k: Float = target > smoothed ? 0.58 : 0.2
        smoothed += (target - smoothed) * k

        let now = Date()
        if peak >= 0.98 { clipUntil = now.addingTimeInterval(0.5) }
        guard now.timeIntervalSince(lastEmit) >= 1.0 / 30 else { return nil }
        lastEmit = now
        return (smoothed, now < clipUntil)
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
