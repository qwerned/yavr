import Foundation

/// Настройки приложения (UserDefaults).
enum Prefs {
    private static let d = UserDefaults.standard

    enum Key {
        static let recognitionModel = "recognitionModel"
        static let useDictionary = "useDictionary"
        static let triggerMode = "triggerMode"  // "hold" | "toggle"
        static let holdModifier = "holdModifier"  // "rightOption" | "rightCommand" | "rightControl"
        static let insertMode = "insertMode"  // "paste" | "clipboard"
        static let microphoneUID = "microphoneUID"  // "" = системный по умолчанию
        static let playSounds = "playSounds"
        static let showPopup = "showPopup"
        static let launchAtLogin = "launchAtLogin"
        static let onboardingDone = "onboardingDone"
        static let language = "language"  // "ru" | "en"
        static let toggleKeyCode = "toggleKeyCode"  // виртуальный keyCode
        static let toggleModifiers = "toggleModifiers"  // NSEvent.ModifierFlags.rawValue
        static let shortcutBehavior = "shortcutBehavior"  // "hold" | "toggle"
        static let duckAudio = "duckAudio"
        static let typingSpeed = "typingSpeed"  // слов/мин, для «сэкономлено»
    }

    static func registerDefaults() {
        d.register(defaults: [
            Key.recognitionModel: RecognitionModel.parakeet.rawValue,
            Key.useDictionary: true,
            Key.triggerMode: "hold",
            Key.holdModifier: "rightOption",
            Key.insertMode: "paste",
            Key.microphoneUID: "",
            Key.playSounds: true,
            Key.showPopup: true,
            Key.launchAtLogin: true,
            Key.onboardingDone: false,
            Key.language: "ru",
            Key.toggleKeyCode: 49,  // Space
            Key.toggleModifiers: 786432,  // ⌃⌥ (.control | .option)
            Key.shortcutBehavior: "hold",
            Key.duckAudio: true,
            Key.typingSpeed: 120,
        ])
    }

    static var recognitionModel: RecognitionModel {
        RecognitionModel(rawValue: d.string(forKey: Key.recognitionModel) ?? "") ?? .parakeet
    }

    static var useDictionary: Bool {
        d.object(forKey: Key.useDictionary) as? Bool ?? true
    }

    static var duckAudio: Bool {
        get { d.bool(forKey: Key.duckAudio) }
        set { d.set(newValue, forKey: Key.duckAudio) }
    }

    static var shortcutBehavior: String {
        get { d.string(forKey: Key.shortcutBehavior) ?? "hold" }
        set { d.set(newValue, forKey: Key.shortcutBehavior) }
    }

    static var toggleKeyCode: Int {
        get { d.integer(forKey: Key.toggleKeyCode) }
        set { d.set(newValue, forKey: Key.toggleKeyCode) }
    }
    static var toggleModifiers: Int {
        get { d.integer(forKey: Key.toggleModifiers) }
        set { d.set(newValue, forKey: Key.toggleModifiers) }
    }

    static var language: String {
        get { d.string(forKey: Key.language) ?? "ru" }
        set { d.set(newValue, forKey: Key.language) }
    }

    /// Языки диктовки в UI. Модель Parakeet v3 поддерживает 25+ европейских
    /// языков (enum Language в FluidAudio) — чтобы добавить язык, достаточно
    /// дописать пару (код ISO, название) в этот список.
    static var dictationLanguages: [(code: String, name: String)] {
        let languages = [(code: "ru", name: "Русский"), (code: "en", name: "English")]
        return recognitionModel == .whisperTurbo
            ? [(code: "auto", name: "Автоопределение")] + languages : languages
    }

    static func languageName(_ code: String) -> String {
        dictationLanguages.first { $0.code == code }?.name ?? code
    }

    static var triggerMode: String {
        get { d.string(forKey: Key.triggerMode) ?? "hold" }
        set { d.set(newValue, forKey: Key.triggerMode) }
    }
    static var holdModifier: String {
        get { d.string(forKey: Key.holdModifier) ?? "rightOption" }
        set { d.set(newValue, forKey: Key.holdModifier) }
    }
    static var insertMode: String {
        get { d.string(forKey: Key.insertMode) ?? "paste" }
        set { d.set(newValue, forKey: Key.insertMode) }
    }
    static var microphoneUID: String {
        get { d.string(forKey: Key.microphoneUID) ?? "" }
        set { d.set(newValue, forKey: Key.microphoneUID) }
    }
    static var playSounds: Bool {
        get { d.bool(forKey: Key.playSounds) }
        set { d.set(newValue, forKey: Key.playSounds) }
    }
    static var showPopup: Bool {
        get { d.bool(forKey: Key.showPopup) }
        set { d.set(newValue, forKey: Key.showPopup) }
    }
    static var launchAtLogin: Bool {
        get { d.bool(forKey: Key.launchAtLogin) }
        set { d.set(newValue, forKey: Key.launchAtLogin) }
    }
    static var onboardingDone: Bool {
        get { d.bool(forKey: Key.onboardingDone) }
        set { d.set(newValue, forKey: Key.onboardingDone) }
    }
}
