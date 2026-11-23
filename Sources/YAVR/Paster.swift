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

    /// Куда попадёт Cmd+V. `.none` — точно некуда: у активного приложения нет
    /// окна в фокусе (рабочий стол) или в фокусе явно не текст (список файлов,
    /// таблица, кнопка). `.unknown` — приложение не отвечает через
    /// Accessibility (бывает у Electron и браузеров): вставляем как раньше.
    enum FocusTarget { case text, none, unknown }

    /// Роли, в которые текст точно не вставить.
    private static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXImage", "AXButton",
        "AXCheckBox", "AXRadioButton", "AXMenu", "AXMenuBar", "AXMenuItem",
    ]
    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    @MainActor
    static func focusTarget() -> FocusTarget {
        guard accessibilityGranted else { return .unknown }
        guard let app = NSWorkspace.shared.frontmostApplication else { return .none }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)

        var window: CFTypeRef?
        switch AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) {
        case .success where window != nil: break
        case .success, .noValue: return .none
        default: return .unknown
        }

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return .unknown }
        let element = focused as! AXUIElement

        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        if textRoles.contains(role) { return .text }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return .text
        }
        return nonTextRoles.contains(role) ? .none : .unknown
    }

    /// Кладёт текст в буфер и, если режим «вставлять» и это возможно, жмёт Cmd+V.
    @MainActor
    static func insert(_ text: String, mode: String) -> Outcome {
        copy(text)
        guard mode == "paste" else { return .copiedOnly(reason: nil) }
        guard accessibilityGranted else {
            return .copiedOnly(reason: "нет разрешения Универсального доступа")
        }
        guard !secureInputActive else { return .copiedOnly(reason: "защищённый ввод (поле пароля)") }
        guard focusTarget() != .none else { return .copiedOnly(reason: "нет поля для вставки") }
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
