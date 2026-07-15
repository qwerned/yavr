import AppKit
import Carbon.HIToolbox
import Foundation

/// Триггеры записи: удержание модификатора (flagsChanged) или удержание
/// кастомного сочетания (Carbon hotkey, pressed+released). Оба — push-to-talk.
@MainActor
final class HotkeyMonitor {
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    var onToggle: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var holdActive = false

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    // keyCode правых модификаторов
    private static let keyCodes: [String: UInt16] = [
        "rightOption": 61,
        "rightCommand": 54,
        "rightControl": 62,
    ]

    func start() {
        stop()
        if Prefs.triggerMode == "hold" {
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
        guard let expectedCode = Self.keyCodes[Prefs.holdModifier],
            event.keyCode == expectedCode
        else { return }

        let modifierPressed: Bool
        switch Prefs.holdModifier {
        case "rightOption": modifierPressed = event.modifierFlags.contains(.option)
        case "rightCommand": modifierPressed = event.modifierFlags.contains(.command)
        case "rightControl": modifierPressed = event.modifierFlags.contains(.control)
        default: return
        }

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
                if Prefs.shortcutBehavior == "toggle" {
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

        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(Prefs.toggleModifiers))
        let hotKeyID = EventHotKeyID(signature: OSType(0x564F_5831), id: 1)  // "VOX1"
        RegisterEventHotKey(
            UInt32(Prefs.toggleKeyCode),
            KeyShortcut.carbonModifiers(from: modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef)
    }
}
