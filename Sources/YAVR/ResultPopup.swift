import AppKit
import SwiftUI

/// Попап с последней диктовкой под иконкой меню-бара; скрывается через ~5 с.
@MainActor
final class ResultPopup {
    private var panel: NSPanel?
    private var hideTimer: Timer?

    struct Content {
        let text: String
        let time: String
        let duration: String
        let statusText: String
        let statusOK: Bool
    }

    func show(_ content: Content, near statusItem: NSStatusItem) {
        hide()

        let view = ResultPopupView(content: content) { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content.text, forType: .string)
            self?.hide()
        }
        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]

        let size = hosting.view.fittingSize
        var origin = NSPoint(x: 0, y: 0)
        if let buttonWindow = statusItem.button?.window, let screen = buttonWindow.screen {
            let buttonFrame = buttonWindow.frame
            origin.x = min(
                buttonFrame.midX - size.width / 2,
                screen.visibleFrame.maxX - size.width - 8)
            origin.y = buttonFrame.minY - size.height - 6
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        hideTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hide() }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ResultPopupView: View {
    let content: ResultPopup.Content
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Последняя диктовка")
                Spacer()
                Text("\(content.time) · \(content.duration)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(content.text)
                    .font(.system(size: 13))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(content.statusOK ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(content.statusText)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Копировать", action: onCopy)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
