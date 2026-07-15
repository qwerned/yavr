import AppKit
import Carbon.HIToolbox
import Foundation

/// Вставка результата: буфер обмена + симуляция Cmd+V с восстановлением буфера.
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

    /// Запрашивает Accessibility с системным промптом.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Кладёт текст в буфер и, если режим «вставлять» и это возможно,
    /// симулирует Cmd+V, после чего восстанавливает прежний буфер.
    @MainActor
    static func insert(_ text: String, mode: String) -> Outcome {
        let pasteboard = NSPasteboard.general

        guard mode == "paste" else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copiedOnly(reason: nil)
        }
        guard accessibilityGranted else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copiedOnly(reason: "нет разрешения Универсального доступа")
        }
        guard !secureInputActive else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copiedOnly(reason: "защищённый ввод (поле пароля)")
        }

        // Сохраняем прежнее содержимое буфера
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? [])
            .map { item in
                var copy: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { copy[type] = data }
                }
                return copy
            }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulateCmdV()

        // Восстанавливаем буфер после того, как вставка успела произойти;
        // свежая диктовка остаётся сверху: восстанавливаем только если
        // пользователь выбрал режим «вставлять + копия в буфере» — по ТЗ
        // копия остаётся, так что прежний буфер НЕ возвращаем, если он
        // перетёр бы результат. Восстановление делаем только при вставке.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // По ТЗ: «вставлять в активное окно + копия в буфер» — значит,
            // после вставки в буфере должен остаться результат диктовки.
            // Прежний буфер восстанавливаем только если он был непустой
            // и режим этого требует. Здесь: оставляем результат в буфере.
            _ = savedItems  // сохранено на случай смены политики
        }
        return .pasted
    }

    /// Симуляция нажатия Cmd+V.
    private static func simulateCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
    }
}
