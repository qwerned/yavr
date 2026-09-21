import AppKit
import Carbon.HIToolbox
import Foundation
import YAVRCore

/// Триггеры записи: удержание модификатора (flagsChanged) или удержание
/// кастомного сочетания (Carbon hotkey, pressed+released). Оба — push-to-talk.
@MainActor
final class HotkeyMonitor {
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    var onToggle: (() -> Void)?
    var isRecording: () -> Bool = { false }

    private struct Configuration: Equatable {
        let triggerMode = Prefs.triggerMode
        let holdModifier = Prefs.holdModifier
        let keyCode = Prefs.toggleKeyCode
        let modifiers = Prefs.toggleModifiers
        let behavior = Prefs.shortcutBehavior
    }
    private var configuration = Configuration()

    private var permissionRefreshPending = false

    func refreshConfiguration(permissionChanged: Bool = false) {
        permissionRefreshPending = permissionRefreshPending || permissionChanged
        guard Configuration() != configuration || permissionRefreshPending, !isRecording() else { return }
        start()
        permissionRefreshPending = false
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var holdActive = false

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func start() {
        guard !isRecording() else { return }
        stop()
        configuration = Configuration()
        if configuration.triggerMode == "hold" {
            startHoldMonitor()
        } else {
            registerToggleHotkey()
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        holdActive = false
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKeyRef = nil
        eventHandler = nil
    }

    // MARK: - Hold-модификатор

    private func startHoldMonitor() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard let modifier = RightModifier(rawValue: configuration.holdModifier),
            event.keyCode == modifier.keyCode
        else { return }

        // Aggregate NSEvent flags cannot distinguish left and right keys.
        let modifierPressed = modifier.isPressed(flags: UInt64(event.modifierFlags.rawValue))

        if modifierPressed && !holdActive {
            holdActive = true
            onHoldStart?()
        } else if !modifierPressed && holdActive {
            holdActive = false
            onHoldEnd?()
        }
    }

    // MARK: - Кастомное сочетание (Carbon, push-to-talk) — работает без Accessibility

    private func registerToggleHotkey() {
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            let kind = GetEventKind(event)
            Task { @MainActor in
                if monitor.configuration.behavior == "toggle" {
                    // Нажал — старт, нажал — стоп (отпускание игнорируем)
                    if kind == UInt32(kEventHotKeyPressed) { monitor.onToggle?() }
                } else {
                    // Держишь и говоришь
                    if kind == UInt32(kEventHotKeyPressed) {
                        monitor.onHoldStart?()
                    } else if kind == UInt32(kEventHotKeyReleased) {
                        monitor.onHoldEnd?()
                    }
                }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(), callback, 2, &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(configuration.modifiers))
        let hotKeyID = EventHotKeyID(signature: OSType(0x5956_5231), id: 1)  // "YVR1"
        RegisterEventHotKey(
            UInt32(configuration.keyCode),
            KeyShortcut.carbonModifiers(from: modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef)
    }
}
