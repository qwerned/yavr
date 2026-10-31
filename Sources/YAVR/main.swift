import AppKit
import SwiftUI
import YAVRCore

// YAVR — menu-bar утилита голосовой диктовки.
// Агентное приложение без Dock-иконки; вся жизнь — в NSStatusItem.

extension Notification.Name {
    /// Результат диктовки (для тестового шага onboarding)
    static let yavrDictation = Notification.Name("yavrDictation")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusController: StatusItemController!
    private let hotkeys = HotkeyMonitor()
    private let recorder = Recorder()
    private let popup = ResultPopup()
    private let indicator = RecordingIndicator()
    private let ducker = AudioDucker()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var onboardingRestoreTask: Task<Void, Never>?

    private var lastResult: String = ""
    private var recordingStart: Date?
    private var session = DictationSession()
    private var transcriptionTask: Task<Void, Never>?
    private var terminationSignal: DispatchSourceSignal?
    private var accessibilityTimer: Timer?
    private var tokenTimer: Timer?
    private var lastAccessibilityGranted = false
    /// Облачная сессия: поток звука, её запуск (nil — ок, иначе текст ошибки)
    /// и живой ввод в поле, если он включён.
    private var cloudAudio: AsyncStream<Data>.Continuation?
    private var cloudStart: Task<String?, Never>?
    private var liveTyper: LiveTyper?

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityTimer?.invalidate()
        tokenTimer?.invalidate()
        transcriptionTask?.cancel()
        session.cancel()
        _ = stopRecordingResources()
        abandonCloudSession()
        hotkeys.stop()
    }

    @discardableResult private func stopRecordingResources() -> [Float] {
        let samples = recorder.stop()
        ducker.restore()
        recordingStart = nil
        indicator.hide()
        return samples
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The installer sends SIGTERM. Route it through AppKit cleanup so audio
        // volume is restored even when an update happens during a recording.
        signal(SIGTERM, SIG_IGN)
        let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal.setEventHandler { NSApp.terminate(nil) }
        terminationSignal.resume()
        self.terminationSignal = terminationSignal
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
        hotkeys.isRecording = { [weak self] in self?.session.phase == .recording }
        hotkeys.start()
        lastAccessibilityGranted = Paster.accessibilityGranted
        let accessibilityTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let granted = Paster.accessibilityGranted
                guard granted != self.lastAccessibilityGranted else { return }
                self.lastAccessibilityGranted = granted
                self.hotkeys.refreshConfiguration(permissionChanged: true)
                self.refreshIdleState()
            }
        }
        RunLoop.main.add(accessibilityTimer, forMode: .common)
        self.accessibilityTimer = accessibilityTimer

        // Токен облака обновляется заранее, чтобы диктовка не ждала обновления;
        // проверка чаще, чем окно, в котором claude соглашается обновлять.
        let tokenTimer = Timer(timeInterval: 2 * 60, repeats: true) { _ in
            Task { @MainActor in
                guard Prefs.recognitionModel.isCloud else { return }
                await CloudTranscriptionService.shared.refreshTokenIfNeeded()
            }
        }
        RunLoop.main.add(tokenTimer, forMode: .common)
        self.tokenTimer = tokenTimer

        // Перезапуск монитора при смене настроек триггера
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hotkeys.refreshConfiguration()
                self?.statusController.refreshLanguageChecks()
            }
        }

        refreshIdleState()
        if Prefs.onboardingDone { LoginItemController.shared.configureAfterOnboarding() }

        if !Prefs.onboardingDone || (Prefs.recognitionModel.needsLocalModel && !TranscriptionService.modelsInstalled()) {
            openOnboarding()
        }
    }

    // MARK: - Диктовка

    private func beginRecording() {
        guard session.phase == .idle else { return }
        let model = Prefs.recognitionModel
        if model.needsLocalModel {
            guard TranscriptionService.modelsInstalled(model: model) else {
                statusController.state = .error("Модель не установлена — откройте настройки")
                return
            }
        }
        if model.isCloud {
            guard CloudTranscriptionService.isAvailable else {
                statusController.state = .error("Нет токена Claude Code — запустите claude auth login")
                return
            }
        }
        guard let sessionID = session.begin() else { return }
        do {
            if Prefs.duckAudio { ducker.duck() }

            if model.isCloud {
                startCloudSession()
            } else {
                recorder.onAudioChunk = nil
            }

            try recorder.start(microphoneUID: Prefs.microphoneUID)
            recordingStart = Date()
            statusController.state = .recording
            indicator.show(.recording)
            if Prefs.playSounds { NSSound(named: "Tink")?.play() }
        } catch {
            _ = stopRecordingResources()
            abandonCloudSession()
            session.finish(sessionID)
            hotkeys.refreshConfiguration()
            statusController.state = .error(error.localizedDescription)
        }
    }

    private func finishRecording() {
        guard session.phase == .recording, let sessionID = session.transcribe() else { return }
        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        let samples = stopRecordingResources()
        recorder.onAudioChunk = nil
        hotkeys.refreshConfiguration()
        if Prefs.playSounds { NSSound(named: "Pop")?.play() }

        let model = Prefs.recognitionModel

        if model.isCloud {
            statusController.state = .transcribing
            indicator.show(.transcribing)
            GlossaryStore.shared.reload()
            let engine = GlossaryStore.shared.replacementEngine
            let useDictionary = Prefs.useDictionary
            // Звука больше не будет: сервис дошлёт накопленное и закроет стрим.
            cloudAudio?.finish()
            cloudAudio = nil
            let start = cloudStart
            let typer = liveTyper
            cloudStart = nil
            liveTyper = nil

            transcriptionTask = Task {
                do {
                    if let startError = await start?.value {
                        throw CloudSTTError.connectionFailed(startError)
                    }
                    let raw = try await CloudTranscriptionService.shared.finishSession()
                    guard !Task.isCancelled, self.session.finish(sessionID) else { return }
                    self.transcriptionTask = nil
                    let text = useDictionary ? engine.apply(to: raw) : raw
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        _ = await typer?.finish(with: "")
                        self.indicator.hide()
                        self.refreshIdleState()
                        return
                    }
                    if let typer, await typer.finish(with: Self.insertable(text)) {
                        self.deliver(text: text, duration: duration, typedLive: true)
                    } else {
                        self.deliver(text: text, duration: duration)
                    }
                } catch {
                    await CloudTranscriptionService.shared.cancel()
                    guard self.session.finish(sessionID) else { return }
                    self.transcriptionTask = nil
                    self.indicator.hide()
                    self.statusController.state = .error(error.localizedDescription)
                }
            }
            return
        }

        guard samples.count > 8000 else {
            session.finish(sessionID)
            indicator.hide()
            refreshIdleState()
            return
        }

        statusController.state = .transcribing
        indicator.show(.transcribing)
        GlossaryStore.shared.reload()
        let glossaryURL = GlossaryStore.shared.fileURL
        let engine = GlossaryStore.shared.replacementEngine
        let language = Prefs.language
        let useDictionary = Prefs.useDictionary

        transcriptionTask = Task {
            do {
                let text = try await TranscriptionService.shared.transcribe(
                    samples: samples, glossaryURL: glossaryURL, engine: engine,
                    languageCode: language, model: model, useDictionary: useDictionary)
                guard !Task.isCancelled, self.session.finish(sessionID) else { return }
                self.transcriptionTask = nil
                self.deliver(text: text, duration: duration)
            } catch {
                guard self.session.finish(sessionID) else { return }
                self.transcriptionTask = nil
                self.indicator.hide()
                self.statusController.state = .error(error.localizedDescription)
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

    /// Пробел в конце, чтобы последовательные диктовки не склеивались.
    private static func insertable(_ text: String) -> String {
        guard let last = text.last, !last.isWhitespace else { return text }
        return text + " "
    }

    /// `typedLive` — текст уже напечатан в поле по ходу диктовки, остаётся
    /// положить его в буфер.
    private func deliver(text: String, duration: TimeInterval, typedLive: Bool = false) {
        indicator.hide()
        lastResult = text
        StatsStore.shared.record(text: text)
        NotificationCenter.default.post(name: .yavrDictation, object: text)

        let insertText = Self.insertable(text)
        let outcome: Paster.Outcome
        if typedLive {
            Paster.copy(insertText)
            outcome = .pasted
        } else {
            outcome = Paster.insert(insertText, mode: Prefs.insertMode)
        }
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

    // MARK: - Облачная сессия

    /// Звук идёт в сервис одним потоком по порядку; подключение идёт
    /// параллельно, и записанное до него ждёт в потоке.
    private func startCloudSession() {
        let (audio, continuation) = AsyncStream<Data>.makeStream()
        cloudAudio = continuation
        recorder.onAudioChunk = { continuation.yield($0) }

        // Живой ввод прямо в поле безопасен, только если во время речи
        // клавиша не удержана: синтетический Cmd+V иначе считается
        // отпусканием модификатора и обрывает запись. В режиме удержания
        // текст виден в облачке и вставляется в конце.
        let keyHeldWhileSpeaking = Prefs.triggerMode == "hold" || Prefs.shortcutBehavior == "hold"
        liveTyper = Prefs.insertMode == "paste" && Paster.canType && !keyHeldWhileSpeaking
            ? LiveTyper() : nil

        let language = Prefs.language
        cloudStart = Task {
            do {
                try await CloudTranscriptionService.shared.startSession(
                    language: language, audio: audio
                ) { [weak self] text in
                    // main-очередь сохраняет порядок черновиков, Task — нет.
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.showDraft(text) } }
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    private func showDraft(_ text: String) {
        guard session.phase == .recording else { return }
        if let liveTyper { liveTyper.update(text) } else { indicator.updateInterimText(text) }
    }

    /// Запись сорвалась или приложение закрывается: дождаться запуска сессии
    /// (иначе она откроется уже после отмены) и закрыть её.
    private func abandonCloudSession() {
        recorder.onAudioChunk = nil
        cloudAudio?.finish()
        cloudAudio = nil
        liveTyper = nil
        let start = cloudStart
        cloudStart = nil
        guard start != nil else { return }
        Task {
            _ = await start?.value
            await CloudTranscriptionService.shared.cancel()
        }
    }

    /// idle или degraded — если вставка выбрана, но невозможна.
    private func refreshIdleState() {
        guard session.phase == .idle else { return }
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
        Paster.copy(lastResult)
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
                rootView: OnboardingView(onMicrophoneRequestCompleted: { [weak self] in
                    self?.restoreOnboardingAfterPermissionPrompt()
                }, onFinish: { [weak self] in
                    Prefs.onboardingDone = true
                    LoginItemController.shared.configureAfterOnboarding()
                    self?.onboardingWindow?.close()
                    self?.refreshIdleState()
                }))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Добро пожаловать в YAVR"
            window.styleMask.remove(.resizable)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.delegate = self
            onboardingWindow = window
        }
        // Keep setup reachable in the Dock while macOS owns the permission prompt.
        NSApp.setActivationPolicy(.regular)
        onboardingWindow?.center()
        presentOnboardingWindow()
    }

    private func restoreOnboardingAfterPermissionPrompt() {
        onboardingRestoreTask?.cancel()
        onboardingRestoreTask = Task { @MainActor [weak self] in
            // The authorization callback can precede dismissal of the system prompt.
            // Let that transition finish before asking AppKit to restore our window.
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            self?.presentOnboardingWindow()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            window === onboardingWindow else { return }
        onboardingRestoreTask?.cancel()
        onboardingRestoreTask = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !Prefs.onboardingDone { openOnboarding() }
        else { openSettings() }
        return true
    }

    private func presentOnboardingWindow() {
        guard let window = onboardingWindow else { return }
        // The system microphone prompt can leave this accessory app behind other apps.
        // Restore focus only after the explicit request, never from permission polling.
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

if CommandLine.arguments.contains("--check-installation") {
    do { try AppResources.checkInstallation(); exit(0) }
    catch { fputs("Installation check failed: \(error)\n", stderr); exit(1) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // держим делегата живым на всё время работы
    objc_setAssociatedObject(app, "yavrDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
