import MenubarCore
import ServiceManagement

/// Open at login through `SMAppService.mainApp`, as Task 0.12 decided: no LaunchAgent plist, and nothing restarts the
/// app after a crash, so Quit stays quit (APP-02).
///
/// Never registered from a test: that would add a real login item to the Mac.
struct MainAppLoginItem: LoginItem {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
