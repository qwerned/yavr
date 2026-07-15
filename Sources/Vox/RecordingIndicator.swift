import AppKit
import SwiftUI

/// Плавающая капсула внизу по центру экрана: «идёт запись» / «распознаю».
@MainActor
final class RecordingIndicator {
    enum Mode {
        case recording
        case transcribing
    }

    private var panel: NSPanel?
    private let model = IndicatorModel()
    private var startTime: Date?
    private var timer: Timer?

    func show(_ mode: Mode) {
        model.mode = mode
        switch mode {
        case .recording:
            startTime = Date()
            model.elapsed = "0:00"
            startTimer()
        case .transcribing:
            stopTimer()
        }
        presentPanel()
    }

    func hide() {
        stopTimer()
        startTime = nil
        panel?.orderOut(nil)
    }

    private func presentPanel() {
        if panel == nil {
            let hosting = NSHostingController(rootView: IndicatorView(model: model))
            let newPanel = NSPanel(
                contentRect: .zero,
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                backing: .buffered, defer: false)
            newPanel.contentViewController = hosting
            newPanel.isFloatingPanel = true
            newPanel.level = .statusBar
            newPanel.backgroundColor = .clear
            newPanel.isOpaque = false
            newPanel.hasShadow = true
            newPanel.ignoresMouseEvents = true
            newPanel.hidesOnDeactivate = false
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = newPanel
        }
        guard let panel, let contentView = panel.contentViewController?.view else { return }

        let size = contentView.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let frame = screen.visibleFrame
            let origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.minY + 28)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startTime = self.startTime else { return }
                let seconds = Int(Date().timeIntervalSince(startTime))
                self.model.elapsed = String(format: "%d:%02d", seconds / 60, seconds % 60)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
private final class IndicatorModel: ObservableObject {
    @Published var mode: RecordingIndicator.Mode = .recording
    @Published var elapsed: String = "0:00"
}

private struct IndicatorView: View {
    @ObservedObject fileprivate var model: IndicatorModel
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            switch model.mode {
            case .recording:
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .opacity(pulsing ? 0.35 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }
                    .onDisappear { pulsing = false }
                Text("Запись · \(model.elapsed)")
                    .monospacedDigit()
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 9, height: 9)
                Text("Распознаю…")
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .fixedSize()
    }
}
