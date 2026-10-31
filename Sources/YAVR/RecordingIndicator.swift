import AppKit
import SwiftUI

/// Плавающая капсула внизу по центру, над Dock: «идёт запись» / «распознаю»,
/// а в режиме удержания — распознаваемый текст. Растёт по высоте под текст,
/// ширина — до половины экрана, фон полупрозрачный.
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

    /// Доля ширины экрана, которую максимум занимает облачко.
    private static let maxWidthFraction: CGFloat = 0.5
    /// Отступ от нижнего края рабочей области (над Dock).
    private static let bottomGap: CGFloat = 12

    func show(_ mode: Mode) {
        model.mode = mode
        model.interimText = ""
        updateMaxWidth()
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
        model.interimText = ""
        panel?.orderOut(nil)
    }

    /// Показывает распознаваемый текст в облачке целиком; облачко растёт
    /// по высоте и переносит строки в пределах половины ширины экрана.
    func updateInterimText(_ text: String) {
        model.interimText = text
        if panel?.isVisible == true { repositionPanel() }
    }

    private func updateMaxWidth() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            model.maxTextWidth = screen.visibleFrame.width * Self.maxWidthFraction
        }
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
        repositionPanel()
        panel?.orderFrontRegardless()
    }

    private func repositionPanel() {
        guard let panel, let contentView = panel.contentViewController?.view else { return }
        contentView.layoutSubtreeIfNeeded()
        let size = contentView.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let frame = screen.visibleFrame
            let origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.minY + Self.bottomGap)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
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
    @Published var interimText: String = ""
    @Published var maxTextWidth: CGFloat = 400
}

private struct IndicatorView: View {
    @ObservedObject fileprivate var model: IndicatorModel
    @State private var pulsing = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            switch model.mode {
            case .recording:
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .opacity(pulsing ? 0.35 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                        value: pulsing)
                    .onAppear { pulsing = true }
                    .onDisappear { pulsing = false }
                    .padding(.top, 4)
                if model.interimText.isEmpty {
                    Text("Запись · \(model.elapsed)")
                        .monospacedDigit()
                } else {
                    Text(model.interimText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: model.maxTextWidth, alignment: .leading)
                }
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 9, height: 9)
                    .padding(.top, 4)
                Text("Распознаю…")
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator, lineWidth: 0.5))
        .opacity(0.92)
        .fixedSize()
    }
}
