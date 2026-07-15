import AVFoundation
import Combine
import SwiftUI

/// Onboarding первого запуска: модель -> микрофон -> Accessibility -> тест.
struct OnboardingView: View {
    @State private var step = 0
    @State private var downloadProgress = 0.0
    @State private var downloading = false
    @State private var downloadError: String?
    @State private var modelReady = TranscriptionService.modelsInstalled()
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var axGranted = Paster.accessibilityGranted
    @State private var testResult = ""
    @State private var permissionTimer: Timer?

    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: modelStep
                case 1: micStep
                case 2: axStep
                default: testStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 7) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 14)
        }
        .frame(width: 470, height: 360)
        .onAppear(perform: startPermissionPolling)
        .onDisappear { permissionTimer?.invalidate() }
        .onReceive(NotificationCenter.default.publisher(for: .voxDictation)) { note in
            if let text = note.object as? String { testResult = text }
        }
    }

    // MARK: Шаг 1 — модель

    private var modelStep: some View {
        StepLayout(
            icon: "waveform",
            title: "Загрузка модели распознавания",
            lead: "YAVR распознаёт речь прямо на этом Mac. Нужна разовая загрузка 570 МБ — ничего не отправляется в интернет."
        ) {
            if modelReady {
                Label("Модель установлена", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if downloading {
                VStack(spacing: 4) {
                    ProgressView(value: downloadProgress)
                    Text("\(Int(downloadProgress * 570)) МБ из 570 МБ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else if let downloadError {
                VStack(spacing: 6) {
                    Text(downloadError).font(.caption).foregroundStyle(.red)
                    Button("Продолжить загрузку") { download() }
                }
            }
        } footer: {
            Spacer()
            if modelReady {
                Button("Дальше") { step = 1 }.keyboardShortcut(.defaultAction)
            } else if !downloading {
                Button("Скачать модель") { download() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Шаг 2 — микрофон

    private var micStep: some View {
        let denied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
        return StepLayout(
            icon: "mic",
            title: "Доступ к микрофону",
            lead: denied
                ? "Доступ был отклонён раньше. Включите YAVR в разделе «Микрофон» Системных настроек — статус здесь обновится сам."
                : "YAVR слушает только пока удерживается клавиша диктовки. macOS спросит разрешение один раз."
        ) {
            Label(
                micGranted ? "Микрофон — разрешён" : "Микрофон — ещё не разрешён",
                systemImage: micGranted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(micGranted ? .green : .secondary)
        } footer: {
            Button("Пропустить") { step = 2 }
            Spacer()
            if micGranted {
                Button("Дальше") { step = 2 }.keyboardShortcut(.defaultAction)
            } else if denied {
                Button("Открыть Системные настройки") {
                    NSWorkspace.shared.open(
                        URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                        )!)
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Разрешить доступ") {
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        Task { @MainActor in micGranted = granted }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Шаг 3 — Accessibility

    private var axStep: some View {
        StepLayout(
            icon: "macwindow.on.rectangle",
            title: "Вставка в другие приложения",
            lead: "Чтобы вставлять текст прямо в место курсора, YAVR нужно разрешение «Универсальный доступ». Без него результат только копируется в буфер."
        ) {
            Label(
                axGranted ? "Универсальный доступ — включён" : "Универсальный доступ — выключен",
                systemImage: axGranted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(axGranted ? .green : .secondary)
        } footer: {
            Button("Пропустить — только буфер") { step = 3 }
            Spacer()
            if axGranted {
                Button("Дальше") { step = 3 }.keyboardShortcut(.defaultAction)
            } else {
                Button("Открыть Системные настройки") {
                    Paster.requestAccessibility()
                    let url = URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    )!
                    NSWorkspace.shared.open(url)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Шаг 4 — тест

    private var testStep: some View {
        StepLayout(
            icon: "waveform.badge.mic",
            title: "Проверим!",
            lead: "Удерживайте правый ⌥ и скажите фразу с рабочими терминами — отпустите, и YAVR её распознает."
        ) {
            Text(testResult.isEmpty ? "Здесь появится распознанный текст…" : testResult)
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(testResult.isEmpty ? .secondary : .primary)
        } footer: {
            Spacer()
            Button("Готово") { onFinish() }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Вспомогательное

    private func download() {
        downloading = true
        downloadError = nil
        Task {
            do {
                try await TranscriptionService.shared.downloadModels { fraction in
                    Task { @MainActor in downloadProgress = fraction }
                }
                await MainActor.run {
                    downloading = false
                    modelReady = TranscriptionService.modelsInstalled()
                }
            } catch {
                await MainActor.run {
                    downloading = false
                    downloadError = "Загрузка прервалась — уже скачанное сохранено, продолжим с того же места."
                }
            }
        }
    }

    /// Accessibility выдаётся в Системных настройках — опрашиваем статус.
    private func startPermissionPolling() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                axGranted = Paster.accessibilityGranted
                micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            }
        }
    }

}

/// Общий каркас шага onboarding.
private struct StepLayout<Content: View, Footer: View>: View {
    let icon: String
    let title: String
    let lead: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            Text(title).font(.title3.bold())
            Text(lead)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            content
                .frame(maxWidth: 360)
            Spacer(minLength: 0)
            HStack { footer }
                .frame(maxWidth: 380)
        }
        .padding(.top, 28)
        .padding(.horizontal, 34)
        .padding(.bottom, 8)
    }
}
