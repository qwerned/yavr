import AppKit
import SwiftUI

/// Поле записи шортката: клик -> «нажмите сочетание…» -> сохранение в Prefs.
/// Esc отменяет запись. Требуется хотя бы один модификатор.
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
                .frame(minWidth: 110)
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
            guard !flags.isEmpty else { return nil }  // без модификатора — игнор
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
