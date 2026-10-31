import AppKit
import Carbon.HIToolbox
import Foundation

/// Вставка результата: текст кладётся в буфер обмена и остаётся там,
/// в активное окно он попадает симуляцией Cmd+V.
enum Paster {
    enum Outcome {
        case pasted  // вставлено в активное окно (+ копия в буфере)
        case copiedOnly(reason: String?)  // только буфер
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var secureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    /// Можно ли сейчас печатать в активное окно синтетическими нажатиями.
    static var canType: Bool { accessibilityGranted && !secureInputActive }

    /// Кладёт текст в буфер и, если режим «вставлять» и это возможно, жмёт Cmd+V.
    @MainActor
    static func insert(_ text: String, mode: String) -> Outcome {
        copy(text)
        guard mode == "paste" else { return .copiedOnly(reason: nil) }
        guard accessibilityGranted else {
            return .copiedOnly(reason: "нет разрешения Универсального доступа")
        }
        guard !secureInputActive else { return .copiedOnly(reason: "защищённый ввод (поле пароля)") }
        press(kVK_ANSI_V, flags: .maskCommand)
        return .pasted
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Вставка без проверок — вызывающий уже убедился в `canType`.
    @MainActor
    static func paste(_ text: String) {
        copy(text)
        press(kVK_ANSI_V, flags: .maskCommand)
    }

    /// Стирает `count` символов перед курсором.
    static func deleteBackward(_ count: Int) {
        for _ in 0..<count { press(kVK_Delete) }
    }

    private static func press(_ key: Int, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
