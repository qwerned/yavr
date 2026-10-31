import AppKit
import SwiftUI

/// Плавающая капсула внизу по центру, над Dock. Шапка со звуковой дорожкой,
/// языком и таймером, под ней распознаваемый текст. Фон полупрозрачный,
/// облачко растёт по высоте вверх под текст; ширина — до трети экрана.
@MainActor
final class RecordingIndicator {
    enum Mode {
        case recording
        case transcribing
    }

    private var panel: NSPanel?
    private var hostingView: NSHostingView<IndicatorView>?
    private let model = IndicatorModel()
    private var startTime: Date?
    private var timer: Timer?

    /// Потолок ширины облачка — треть экрана.
    private static let maxWidthFraction: CGFloat = 1.0 / 3.0
    /// Минимальная ширина облачка (хватает на шапку).
    private static let minWidth: CGFloat = 240
    /// Отступ от нижнего края рабочей области (над Dock).
    private static let bottomGap: CGFloat = 12
    /// Горизонтальные поля внутри облачка (padding слева+справа).
    private static let hInset: CGFloat = 32
    /// Высота шапки (padding 10+10 + содержимое 16).
    private static let headerHeight: CGFloat = 36
    /// Всё, кроме самого текста: шапка + разделитель + поля блока текста.
    private static let chromeHeight: CGFloat = headerHeight + 1 + 11 + 14

    static func wordCount(_ text: String) -> String { russianWordCount(text) }

    func show(_ mode: Mode) {
        model.mode = mode
        model.interimText = ""
        model.lang = String(Prefs.language.prefix(2)).uppercased()
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

    /// Показывает распознаваемый текст; облачко пересчитывает размер и растёт
    /// по высоте, перенося строки в пределах половины ширины экрана.
    func updateInterimText(_ text: String) {
        model.interimText = text
        // Раскладка SwiftUI применяет изменение на следующем тике main.
        DispatchQueue.main.async { [weak self] in self?.sizeAndAnchor() }
    }

    private func presentPanel() {
        if panel == nil {
            let view = NSHostingView(rootView: IndicatorView(model: model))
            let newPanel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: Self.minWidth, height: 44),
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                backing: .buffered, defer: false)
            // contentView напрямую, а не contentViewController: иначе окно
            // само переразмеряется под контент с привязкой к верхнему углу и
            // уползает вниз, перекрывая наш setFrame.
            view.autoresizingMask = [.width, .height]
            // Иначе хостинг сам подгоняет окно под свой контент, держа на месте
            // верхний край, — и нижний уезжает на Dock. Размер задаёт только
            // sizeAndAnchor.
            view.sizingOptions = []
            newPanel.contentView = view
            newPanel.isFloatingPanel = true
            newPanel.level = .statusBar
            newPanel.backgroundColor = .clear
            newPanel.isOpaque = false
            newPanel.hasShadow = true
            newPanel.ignoresMouseEvents = true
            newPanel.hidesOnDeactivate = false
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            hostingView = view
            panel = newPanel
        }
        sizeAndAnchor()
        panel?.orderFrontRegardless()
    }

    /// Считает размер облачка отдельным замерочным хостингом и ставит панель
    /// внизу по центру. Замер детерминированный: фиксируем ширину — получаем
    /// честную высоту при переносе строк.
    private func sizeAndAnchor() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame

        let maxWidth = (visible.width * Self.maxWidthFraction).rounded()

        let width: CGFloat
        let height: CGFloat
        if model.mode == .recording {
            let display = displayText()
            // Ширина под текст, но не уже шапки и не шире трети экрана.
            let ideal = ceil(textSize(display, width: 100_000).width) + Self.hInset
            width = min(max(ideal, Self.minWidth), maxWidth)
            // Высота — реальная высота текста при этой ширине (растём вверх).
            let textH = textSize(display, width: width - Self.hInset).height
            height = ceil(Self.chromeHeight + textH + 3)  // +3 — защита от обрезки
        } else {
            width = Self.minWidth
            height = Self.headerHeight  // распознавание — только шапка
        }

        let size = NSSize(width: width.rounded(), height: height)
        // Нижний край прибит над Dock (origin.y постоянный) — облачко растёт
        // только вверх, высотой.
        let origin = NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: visible.minY + Self.bottomGap)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Строка, которую реально рисует облачко (с хвостом-счётчиком слов).
    private func displayText() -> String {
        guard !model.interimText.isEmpty else { return "Говорите…" }
        return model.interimText + "  · " + Self.wordCount(model.interimText)
    }

    /// Размер текста при заданной ширире (переносом), шрифт и межстрочный
    /// интервал — те же, что в IndicatorView.
    private func textSize(_ s: String, width: CGFloat) -> CGSize {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 2
        let attr = NSAttributedString(
            string: s,
            attributes: [.font: NSFont.systemFont(ofSize: 15), .paragraphStyle: ps])
        let r = attr.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(r.width), height: ceil(r.height))
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
    @Published var lang: String = "RU"
}

/// Индиго-акцент дорожки (из design/yavr-ui-mock.html).
private let waveAccent = Color(.sRGB, red: 94 / 255, green: 92 / 255, blue: 230 / 255)

private struct IndicatorView: View {
    @ObservedObject fileprivate var model: IndicatorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            if model.mode == .recording {
                Divider().overlay(Color.primary.opacity(0.10))
                transcriptView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }

    @ViewBuilder private var headerView: some View {
        HStack(spacing: 10) {
            switch model.mode {
            case .recording:
                PulsingDot()
                Waveform()
                Spacer(minLength: 8)
                Text(model.lang)
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                Text(model.elapsed)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            case .transcribing:
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text("Распознаю…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var transcriptView: some View {
        Group {
            if model.interimText.isEmpty {
                Text("Говорите…")
                    .foregroundStyle(.tertiary)
            } else {
                Text(model.interimText)
                    + Text("  · \(russianWordCount(model.interimText))")
                    .foregroundColor(.secondary)
            }
        }
        .font(.system(size: 15, weight: .regular))
        .lineSpacing(2)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 11)
        .padding(.bottom, 14)
    }
}

/// «2 слова», «5 слов» — счётчик для хвоста реплики. Один и тот же для
/// отрисовки и для замера размеров облачка, чтобы они совпадали.
func russianWordCount(_ text: String) -> String {
    let n = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    let a = n % 100, b = n % 10
    let noun: String
    if a >= 11 && a <= 14 { noun = "слов" }
    else if b == 1 { noun = "слово" }
    else if b >= 2 && b <= 4 { noun = "слова" }
    else { noun = "слов" }
    return "\(n) \(noun)"
}

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 9, height: 9)
            .opacity(on ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .onDisappear { on = false }
    }
}

private struct Waveform: View {
    @State private var animating = false
    private let heights: [CGFloat] = [6, 12, 16, 9, 13, 6]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule()
                    .fill(waveAccent)
                    .frame(width: 2.5, height: heights[i])
                    .scaleEffect(y: animating ? 1.0 : 0.5, anchor: .center)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.12),
                        value: animating)
            }
        }
        .frame(height: 16)
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }
}
