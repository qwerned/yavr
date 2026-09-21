import AppKit
import ServiceManagement

@MainActor
final class LoginItemController: ObservableObject {
    static let shared = LoginItemController()
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var error: String?

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ value: Bool) {
        error = nil
        do {
            let status = SMAppService.mainApp.status
            if value && status != .enabled && status != .requiresApproval {
                try SMAppService.mainApp.register()
            } else if !value && (status == .enabled || status == .requiresApproval) {
                try SMAppService.mainApp.unregister()
            }
            Prefs.launchAtLogin = value
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        } catch {
            self.error = "Не удалось изменить автозапуск: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Preserve existing intent; initialize only once, after onboarding.
    func configureAfterOnboarding() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard !UserDefaults.standard.bool(forKey: "loginItemConfigured") else { refresh(); return }
        setEnabled(Prefs.launchAtLogin)
        if error == nil { UserDefaults.standard.set(true, forKey: "loginItemConfigured") }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
