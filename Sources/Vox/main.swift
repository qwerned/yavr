import AppKit
import SwiftUI

// Vox — menu-bar утилита голосовой диктовки.
// Агентное приложение без Dock-иконки; вся жизнь — в NSStatusItem.

extension Notification.Name {
    /// Результат диктовки (для тестового шага onboarding)
    static let voxDictation = Notification.Name("voxDictation")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController!
    private let hotkeys = HotkeyMonitor()
    private let recorder = Recorder()
    private let popup = ResultPopup()
    private let indicator = RecordingIndicator()
    private let ducker = AudioDucker()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    private var lastResult: String = ""
    private var recordingStart: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        NSApp.setActivationPolicy(.accessory)

        statusController = StatusItemController()
        _ = GlossaryStore.shared

        recorder.onLimitReached = { [weak self] in
            self?.finishRecording()
        }

        hotkeys.onHoldStart = { [weak self] in self?.beginRecording() }
        hotkeys.onHoldEnd = { [weak self] in self?.finishRecording() }
        hotkeys.onToggle = { [weak self] in self?.toggleDictationInternal() }
        hotkeys.start()

        // Перезапуск монитора при смене настроек триггера
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hotkeys.start()
            }
        }

        refreshIdleState()

        if !Prefs.onboardingDone || !TranscriptionService.modelsInstalled() {
            openOnboarding()
        }
    }

    // MARK: - Диктовка

    private func beginRecording() {
        guard !recorder.isRecording else { return }
        guard TranscriptionService.modelsInstalled() else {
            statusController.state = .error("Модель не установлена — откройте настройки")
            return
        }
        do {
            if Prefs.duckAudio { ducker.duck() }
            try recorder.start(microphoneUID: Prefs.microphoneUID)
            recordingStart = Date()
            statusController.state = .recording
            indicator.show(.recording)
            if Prefs.playSounds { NSSound(named: "Tink")?.play() }
        } catch {
            statusController.state = .error(error.localizedDescription)
        }
    }

    private func finishRecording() {
        guard recorder.isRecording else { return }
        let samples = recorder.stop()
        ducker.restore()
        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        recordingStart = nil
        if Prefs.playSounds { NSSound(named: "Pop")?.play() }

        guard samples.count > 8000 else {
            indicator.hide()
            refreshIdleState()
            return
        }

        statusController.state = .transcribing
        indicator.show(.transcribing)
        // Перечитываем глоссарий: ручные правки файла работают без перезапуска
        GlossaryStore.shared.reload()
        let glossaryURL = GlossaryStore.shared.fileURL
        let engine = GlossaryStore.shared.replacementEngine
        let language = Prefs.language

        Task {
            do {
                let text = try await TranscriptionService.shared.transcribe(
                    samples: samples, glossaryURL: glossaryURL, engine: engine,
                    languageCode: language)
                await MainActor.run { self.deliver(text: text, duration: duration) }
            } catch {
                await MainActor.run {
                    self.indicator.hide()
                    self.statusController.state = .error(error.localizedDescription)
                }
            }
        }
    }

    private func toggleDictationInternal() {
        if recorder.isRecording {
            finishRecording()
        } else {
            beginRecording()
        }
    }

    private func deliver(text: String, duration: TimeInterval) {
        indicator.hide()
        lastResult = text
        StatsStore.shared.record(text: text)
        NotificationCenter.default.post(name: .voxDictation, object: text)

        // Пробел в конце, чтобы последовательные диктовки не склеивались
        var insertText = text
        if let last = text.last, !last.isWhitespace {
            insertText += " "
        }
        let outcome = Paster.insert(insertText, mode: Prefs.insertMode)
        let statusText: String
        let ok: Bool
        switch outcome {
        case .pasted:
            statusText = "Вставлено в активное окно"
            ok = true
        case .copiedOnly(let reason):
            if let reason {
                statusText = "Скопировано — вставка недоступна (\(reason))"
                ok = false
            } else {
                statusText = "Скопировано в буфер"
                ok = true
            }
        }

        refreshIdleState()

        if Prefs.showPopup {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            popup.show(
                ResultPopup.Content(
                    text: text,
                    time: formatter.string(from: Date()),
                    duration: String(format: "%.1f c", duration),
                    statusText: statusText,
                    statusOK: ok),
                near: statusController.statusItem)
        }
    }

    /// idle или degraded — если вставка выбрана, но невозможна.
    private func refreshIdleState() {
        if Prefs.insertMode == "paste" && !Paster.accessibilityGranted {
            statusController.state = .degraded(
                "Вставка недоступна (нет Универсального доступа) — только буфер")
        } else {
            statusController.state = .idle
        }
    }

    // MARK: - Действия меню

    @objc func toggleDictation() {
        toggleDictationInternal()
    }

    @objc func setLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        Prefs.language = code
        statusController.refreshLanguageChecks()
    }

    @objc func copyLastResult() {
        guard !lastResult.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastResult, forType: .string)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            // Нативные вкладки-тулбар, как в системных настройках macOS
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar

            func makeTab<Content: View>(
                _ view: Content, title: String, icon: String
            ) -> NSTabViewItem {
                let hosting = NSHostingController(rootView: view)
                hosting.sizingOptions = .preferredContentSize
                hosting.title = "Настройки YAVR — \(title)"
                let item = NSTabViewItem(viewController: hosting)
                item.label = title
                item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
                return item
            }

            tabs.tabViewItems = [
                makeTab(GeneralTab(), title: "Основные", icon: "gearshape"),
                makeTab(DictionaryTab(), title: "Словарь", icon: "character.book.closed"),
                makeTab(StatsTab(), title: "Статистика", icon: "chart.bar"),
                makeTab(AboutTab(), title: "О программе", icon: "info.circle"),
            ]

            let window = NSWindow(contentViewController: tabs)
            window.title = "Настройки YAVR"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func reopenOnboarding() {
        openOnboarding()
    }

    @objc func openAbout() {
        openSettings()
        // Вкладка «О программе» выбирается пользователем; отдельного окна нет
    }

    func openOnboarding() {
        if onboardingWindow == nil {
            let hosting = NSHostingController(
                rootView: OnboardingView { [weak self] in
                    Prefs.onboardingDone = true
                    self?.onboardingWindow?.close()
                    self?.refreshIdleState()
                })
            let window = NSWindow(contentViewController: hosting)
            window.title = "Добро пожаловать в YAVR"
            window.styleMask.remove(.resizable)
            window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.center()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // держим делегата живым на всё время работы
    objc_setAssociatedObject(app, "voxDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
