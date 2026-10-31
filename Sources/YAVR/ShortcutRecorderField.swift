import AppKit
import SwiftUI

/// Поле записи шортката: клик -> «нажмите сочетание…» -> сохранение в Prefs.
/// Esc отменяет запись. Требуется ⌘, ⌥ или ⌃.
struct ShortcutRecorderField: View {
    @State private var recording = false
    @State private var display = ShortcutRecorderField.currentDisplay()
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stopRecording() : startRecording()
        } label: {
            Text(recording ? "нажмите сочетание…" : display)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 150)
        }
        .onDisappear(perform: stopRecording)
    }

    private static func currentDisplay() -> String {
        KeyShortcut.displayString(
            keyCode: Prefs.toggleKeyCode,
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(Prefs.toggleModifiers)))
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc — отмена
                stopRecording()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Нужен ⌘, ⌥ или ⌃: глобальный Shift+буква перехватил бы набор заглавных
            guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
            Prefs.toggleKeyCode = Int(event.keyCode)
            Prefs.toggleModifiers = Int(flags.rawValue)
            display = KeyShortcut.displayString(keyCode: Int(event.keyCode), modifiers: flags)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
