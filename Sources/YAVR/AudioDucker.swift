import CoreAudio
import Foundation

/// Приглушение системного звука на время записи: опускаем громкость
/// устройства вывода до 10% и восстанавливаем после. Работает с любым
/// источником звука (Музыка, Spotify, браузер) без дополнительных разрешений.
@MainActor
final class AudioDucker {
    private struct SavedVolume {
        let deviceID: AudioDeviceID
        let element: UInt32
        let volume: Float32
    }

    private var saved: [SavedVolume] = []

    func duck() {
        guard saved.isEmpty, let device = Self.defaultOutputDevice() else { return }
        // element 0 — master; 1, 2 — каналы (не у всех устройств есть master)
        for element: UInt32 in [0, 1, 2] {
            guard let volume = Self.getVolume(device: device, element: element) else { continue }
            saved.append(SavedVolume(deviceID: device, element: element, volume: volume))
            Self.setVolume(device: device, element: element, value: min(volume, 0.1))
        }
    }

    func restore() {
        for item in saved {
            Self.setVolume(device: item.deviceID, element: item.element, value: item.volume)
        }
        saved.removeAll()
    }

    // MARK: - CoreAudio

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private static func volumeAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
    }

    private static func getVolume(device: AudioDeviceID, element: UInt32) -> Float32? {
        var address = volumeAddress(element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr
        else { return nil }
        return volume
    }

    private static func setVolume(device: AudioDeviceID, element: UInt32, value: Float32) {
        var address = volumeAddress(element)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
            settable.boolValue
        else { return }
        var volume = value
        AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
    }
}
