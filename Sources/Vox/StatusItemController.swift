import AppKit
import Foundation

enum VoxState: Equatable {
    case idle
    case recording
    case transcribing
    case error(String)
    /// idle, но вставка недоступна — ненавязчивая индикация
    case degraded(String)
}

/// Иконка в меню-баре: waveform в четырёх состояниях + меню.
@MainActor
final class StatusItemController {
    let statusItem: NSStatusItem
    private var pulseTimer: Timer?
    private var pulseOn = false

    var state: VoxState = .idle {
        didSet { render() }
    }

    // Пункты меню, которые обновляются по состоянию
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let dictateItem = NSMenuItem(
        title: "Начать диктовку", action: #selector(AppDelegate.toggleDictation), keyEquivalent: "")
    private let copyLastItem = NSMenuItem(
        title: "Скопировать последний результат", action: #selector(AppDelegate.copyLastResult),
        keyEquivalent: "c")
    private var languageMenu: NSMenu?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.addItem(dictateItem)
        copyLastItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(copyLastItem)
        menu.addItem(.separator())

        // Быстрый переключатель языка диктовки — все языки модели
        let languageItem = NSMenuItem(title: "Язык диктовки", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for (index, lang) in Prefs.dictationLanguages.enumerated() {
            let item = NSMenuItem(
                title: lang.name, action: #selector(AppDelegate.setLanguage(_:)),
                keyEquivalent: "")
            item.representedObject = lang.code
            languageMenu.addItem(item)
            if index == 1 { languageMenu.addItem(.separator()) }  // ru/en сверху
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        self.languageMenu = languageMenu
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Настройки…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        menu.addItem(settingsItem)
        menu.addItem(
            NSMenuItem(
                title: "О программе YAVR", action: #selector(AppDelegate.openAbout), keyEquivalent: ""))
        menu.addItem(
            NSMenuItem(
                title: "Пройти настройку заново…",
                action: #selector(AppDelegate.reopenOnboarding), keyEquivalent: ""))
        menu.addItem(.separator())

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Завершить YAVR", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        render()
    }

    private func render() {
        guard let button = statusItem.button else { return }
        stopPulse()

        // В меню-баре contentTintColor для template-иконок игнорируется,
        // поэтому цветные состояния — это отдельные окрашенные символы.
        switch state {
        case .idle:
            button.image = symbol("waveform", tint: nil)
            statusLine.title = "Готов к диктовке"
        case .recording:
            button.image = symbol("waveform", tint: .systemRed)
            statusLine.title = "Идёт запись…"
        case .transcribing:
            button.image = symbol("waveform", tint: .secondaryLabelColor)
            statusLine.title = "Распознаю…"
            startPulse()
        case .error(let message):
            button.image =
                symbol("waveform.badge.exclamationmark", tint: .systemOrange)
                ?? symbol("waveform", tint: .systemOrange)
            statusLine.title = message
        case .degraded(let message):
            button.image =
                symbol("waveform.badge.exclamationmark", tint: nil)
                ?? symbol("waveform", tint: nil)
            statusLine.title = message
        }

        dictateItem.title = state == .recording ? "Остановить и распознать" : "Начать диктовку"
        refreshLanguageChecks()
    }

    /// Обновить галочки языка (после переключения из меню)
    func refreshLanguageChecks() {
        for item in languageMenu?.items ?? [] {
            item.state = (item.representedObject as? String) == Prefs.language ? .on : .off
        }
    }

    private func symbol(_ name: String, tint: NSColor?) -> NSImage? {
        var image = NSImage(systemSymbolName: name, accessibilityDescription: "Vox")
        if let tint {
            let config = NSImage.SymbolConfiguration(paletteColors: [tint])
            image = image?.withSymbolConfiguration(config)
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        return image
    }

    private func startPulse() {
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let button = self.statusItem.button else { return }
                self.pulseOn.toggle()
                button.image = self.symbol(
                    "waveform", tint: self.pulseOn ? .labelColor : .tertiaryLabelColor)
            }
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseOn = false
    }
}
