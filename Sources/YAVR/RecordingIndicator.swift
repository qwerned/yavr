import AppKit
import SwiftUI

/// Однострочная капсула записи внизу по центру, над Dock:
/// × · точки громкости · текст · таймер · ✓.
/// Все цвета системные: капсула следует светлой/тёмной теме и акцентному
/// цвету из Системных настроек. Панель не забирает фокус у активного
/// приложения, но кнопки реагируют на первый же клик.
@MainActor
final class RecordingIndicator {
    enum Mode: Equatable {
        case recording
        case transcribing
        case error(String)
        /// Короткое сообщение без ошибки («Скопировано в буфер…»).
        case notice(String)
    }

    /// Кнопка ×: те же действия, что у отмены диктовки.
    var onCancel: (() -> Void)?
    /// Кнопка ✓: остановить запись и распознать.
    var onFinish: (() -> Void)?

    private var panel: NSPanel?
    private let model = IndicatorModel()
    private var startTime: Date?
    private var timer: Timer?
    private var autoHideTask: Task<Void, Never>?
    private var colorObserver: NSObjectProtocol?

    private static let height: CGFloat = 40
    private static let maxWidth: CGFloat = 440
    /// Отступ от нижнего края рабочей области (над Dock).
    private static let bottomGap: CGFloat = 12
    /// Сдвиг снизу вверх при появлении.
    private static let appearOffset: CGFloat = 6
    /// Ошибка висит столько, если её не закрыли кнопкой ×.
    private static let errorDuration: Duration = .seconds(5)
    private static let noticeDuration: Duration = .seconds(3)

    /// `streamsText` — движок присылает текст по ходу речи (облако без живого
    /// ввода в поле): пока текста нет, а речь идёт, вместо статуса пульсируют точки.
    func show(_ mode: Mode, streamsText: Bool = false) {
        autoHideTask?.cancel()
        autoHideTask = nil
        switch mode {
        case .recording:
            model.interimText = ""
            model.streamsText = streamsText
            model.level = 0
            model.clipping = false
            model.heardSpeech = false
            startTime = Date()
            model.elapsed = "0:00"
            startTimer()
        case .transcribing:
            // Таймер замирает, уже показанный текст остаётся.
            stopTimer()
            model.level = 0
            model.clipping = false
        case .error, .notice:
            stopTimer()
            let duration: Duration
            if case .error = mode { duration = Self.errorDuration } else { duration = Self.noticeDuration }
            autoHideTask = Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
        model.languageName = Prefs.languageName(Prefs.language)
        model.mode = mode
        present()
    }

    func showError(_ message: String) { show(.error(message)) }
    func showNotice(_ message: String) { show(.notice(message)) }

    func hide() {
        stopTimer()
        autoHideTask?.cancel()
        autoHideTask = nil
        startTime = nil
        model.interimText = ""
        model.level = 0
        model.clipping = false
        panel?.orderOut(nil)
    }

    func updateInterimText(_ text: String) {
        model.interimText = text
    }

    func updateLevel(_ level: Float, clipping: Bool) {
        guard model.mode == .recording else { return }
        if clipping && !model.clipping {
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [
                    .announcement: "Слишком громко",
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
        model.level = Double(level)
        model.clipping = clipping
        if level > 0.12 && !model.heardSpeech { model.heardSpeech = true }
    }

    // MARK: - Панель

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.maxWidth, height: Self.height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Системный материал всплывающих окон: сам подстраивается под тему
        // и под «Уменьшить прозрачность» (становится непрозрачным).
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.capsuleMask(height: Self.height)

        let hosting = FirstMouseHostingView(rootView: IndicatorView(
            model: model,
            onCancel: { [weak self] in self?.onCancel?() },
            onFinish: { [weak self] in self?.onFinish?() }))
        hosting.sizingOptions = []
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        panel.contentView = effect

        // Смена акцентного цвета не всегда перерисовывает SwiftUI сама.
        colorObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.colorEpoch += 1 }
        }
        return panel
    }

    /// Растягиваемая маска-капсула: скруглены только торцы.
    private static func capsuleMask(height: CGFloat) -> NSImage {
        let radius = height / 2
        let size = NSSize(width: height + 1, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func targetFrame() -> NSRect? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let visible = screen.visibleFrame
        let width = min(Self.maxWidth, screen.frame.width - 32).rounded()
        return NSRect(
            x: (visible.midX - width / 2).rounded(),
            y: visible.minY + Self.bottomGap,
            width: width, height: Self.height)
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let frame = targetFrame() else { return }

        if panel.isVisible {
            panel.setFrame(frame, display: true)
            return
        }

        // Появление: проявление за 180 мс и сдвиг на 6 pt снизу вверх
        // (сдвиг — только если не включено «Уменьшить движение»).
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var start = frame
        if !reduceMotion { start.origin.y -= Self.appearOffset }
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    // MARK: - Таймер

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

/// Кнопки неактивной панели срабатывают с первого клика.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class IndicatorModel: ObservableObject {
    @Published var mode: RecordingIndicator.Mode = .recording
    @Published var elapsed = "0:00"
    @Published var interimText = ""
    @Published var languageName = ""
    @Published var streamsText = false
    @Published var level: Double = 0
    @Published var clipping = false
    /// В этой записи уже звучала речь: ждём текст от движка.
    @Published var heardSpeech = false
    @Published var colorEpoch = 0
}

// MARK: - Вью

private extension Color {
    static let label = Color(nsColor: .labelColor)
    static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
    static let quaternaryLabel = Color(nsColor: .quaternaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
    static let systemRed = Color(nsColor: .systemRed)
    static let controlAccent = Color(nsColor: .controlAccentColor)
}

private struct IndicatorView: View {
    @ObservedObject var model: IndicatorModel
    let onCancel: () -> Void
    let onFinish: () -> Void

    private var isError: Bool {
        if case .error = model.mode { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            CancelButton(action: onCancel)
            switch model.mode {
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.systemRed)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(message)
            case .notice(let message):
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondaryLabel)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(message)
            case .recording, .transcribing:
                LevelDots(
                    level: model.level, clipping: model.clipping,
                    recording: model.mode == .recording)
                TranscriptLine(
                    text: model.interimText,
                    recording: model.mode == .recording,
                    waitingForText: model.streamsText && model.heardSpeech)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(model.elapsed)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Color.secondaryLabel)
                    .frame(width: 36, alignment: .trailing)
                    .help("Язык: \(model.languageName)")
                if model.mode == .recording {
                    FinishButton(action: onFinish).id(model.colorEpoch)
                } else {
                    Circle()
                        .fill(Color.quaternaryLabel)
                        .frame(width: 24, height: 24)
                        .overlay(ProgressView().controlSize(.small).scaleEffect(0.75))
                        .accessibilityLabel("Распознаю")
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            Capsule().strokeBorder(
                isError ? Color.systemRed.opacity(0.4) : Color.separator, lineWidth: 1))
    }
}

private struct CancelButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14))
                .foregroundStyle(Color.secondaryLabel)
                .frame(width: 24, height: 24)
                .background(Circle().fill(hovering ? Color.quaternaryLabel : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Отменить")
        .accessibilityLabel("Отменить")
    }
}

private struct FinishButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.controlAccent))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Готово")
        .accessibilityLabel("Готово")
    }
}

/// 9 точек, которые растут и расходятся по вертикали вместе с громкостью.
private struct LevelDots: View {
    let level: Double
    let clipping: Bool
    let recording: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// (base, response, lift) для каждой точки.
    private static let dots: [(base: Double, response: Double, lift: Double)] = [
        (0.64, 0.45, 1), (0.76, 0.75, -1), (0.90, 1.00, 1),
        (1.00, 1.25, -1), (0.86, 0.90, 1), (0.72, 1.10, -1),
        (0.82, 0.70, 1), (0.68, 0.55, -1), (0.58, 0.35, 1),
    ]

    var body: some View {
        let shown = recording ? level : 0
        TimelineView(.animation(paused: recording || reduceMotion)) { context in
            HStack(spacing: 1) {
                ForEach(Self.dots.indices, id: \.self) { i in
                    let dot = Self.dots[i]
                    Circle()
                        .fill(clipping ? Color.systemRed : Color.label.opacity(0.8))
                        .frame(width: 4, height: 4)
                        .scaleEffect(dot.base + shown * dot.response)
                        .offset(y: shown * dot.lift * 2)
                }
            }
            .frame(width: 44, height: 24)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: shown)
            .opacity(pulseOpacity(at: context.date))
        }
        .accessibilityHidden(true)
    }

    /// Распознавание: блок мягко пульсирует прозрачностью.
    private func pulseOpacity(at date: Date) -> Double {
        guard !recording, !reduceMotion else { return 1 }
        let phase = date.timeIntervalSinceReferenceDate * 2 * .pi / 1.4
        return 0.65 + 0.35 * cos(phase)
    }
}

/// Одна строка текста. Если не влезает — прижата вправо (последние слова
/// видны), левый край растворяется.
private struct TranscriptLine: View {
    let text: String
    let recording: Bool
    let waitingForText: Bool

    private static let fadeWidth: CGFloat = 24

    var body: some View {
        if text.isEmpty {
            if recording && waitingForText {
                TypingDots()
            } else {
                Text(recording ? "Слушаю…" : "Распознаю…")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                line
                line
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                    .clipped()
                    .mask(
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                .frame(width: Self.fadeWidth)
                            Rectangle()
                        })
            }
            .accessibilityElement()
            .accessibilityLabel(text)
        }
    }

    private var line: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.label)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Три пульсирующие точки: речь идёт, текст вот-вот появится.
private struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.secondaryLabel)
                        .frame(width: 4, height: 4)
                        .opacity(opacity(i, at: context.date))
                }
            }
        }
        .accessibilityLabel("Слушаю")
    }

    private func opacity(_ index: Int, at date: Date) -> Double {
        guard !reduceMotion else { return 1 }
        let t = date.timeIntervalSinceReferenceDate - Double(index) * 0.15
        return 0.3 + 0.7 * (0.5 + 0.5 * sin(t * 2 * .pi / 0.9))
    }
}
