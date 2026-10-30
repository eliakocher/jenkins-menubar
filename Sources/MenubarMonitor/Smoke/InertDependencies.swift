import Foundation
import MenubarCore
import os

// What the smoke check and the throwaway mode use instead of the parts that would reach the user's keychain, login
// items, screen or speakers. They are in release builds too, since the smoke check runs the bundle `build.sh` makes.

/// A keychain that keeps its values in memory only, so the login keychain is never touched.
actor MemoryKeychain: Keychain {
    private var values: [String: String] = [:]

    func find(account: String) -> String? {
        values[account]
    }

    func store(_ value: String, account: String) {
        values[account] = value
    }

    func delete(account: String) {
        values[account] = nil
    }
}

/// Effects that only collect what they were asked to do; nothing shows or sounds.
actor SmokeEffects: Effects {
    /// what was asked, one line each, like `banner ✅ !1 #7 SUCCESS`
    private(set) var calls: [String] = []

    func showAlertWindow(_ alert: BuildAlert) {
        calls.append("alert window \(alert.content.headline)")
    }

    func postBanner(_ alert: BuildAlert) -> Bool {
        calls.append("banner \(alert.content.headline)")
        return true
    }

    func playSound(_ sound: AlertContent.Sound) {
        calls.append("sound \(sound.rawValue)")
    }
}

/// A login item that only remembers on and off in memory, so no run of this kind adds one to the Mac, and turning it on
/// still works for whoever looks at the app: the switch shows the state, with no red problem.
@MainActor
final class InertLoginItem: LoginItem {
    private static let logger = Logger(subsystem: AppIdentity.bundleID, category: "app")

    private(set) var status: LoginItemStatus = .notRegistered

    func register() throws {
        Self.logger.info("throwaway: no login item registered")
        status = .enabled
    }

    func unregister() throws {
        status = .notRegistered
    }

    func openSystemSettings() {}
}

/// Sleep and wake that never come.
struct NoSystemEvents: SystemEvents {
    func events() -> AsyncStream<SystemEvent> {
        AsyncStream { _ in }
    }
}

/// A hotkey registration that registers nothing, so a throwaway or smoke run never takes the shortcut of the user's own
/// app, or any on the Mac.
@MainActor
final class InertHotkeys: HotkeyRegistrar {
    func register(_ shortcut: HotkeyShortcut, onPress: @escaping @MainActor () -> Void) throws {}

    func unregister() {}
}

/// A default browser that lives in memory, so a throwaway or smoke run never changes the Mac's: the router's switch
/// works for whoever looks at the app, and links open nowhere.
@MainActor
final class InertDefaultBrowser: DefaultBrowserSystem {
    private static let safari = BrowserApp(url: URL(filePath: "/Applications/Safari.app"), bundleID: "com.apple.Safari", name: "Safari")
    private static let this = BrowserApp(
        url: URL(filePath: "/Applications/\(AppIdentity.bundleFileName)"), bundleID: AppIdentity.bundleID, name: AppIdentity.displayName)

    private var current: BrowserApp? = InertDefaultBrowser.safari

    var thisApp: BrowserApp? { Self.this }
    func defaultBrowser() -> BrowserApp? { current }
    func app(bundleID: String) -> BrowserApp? { bundleID == Self.safari.bundleID ? Self.safari : nil }
    func exists(_ app: BrowserApp) -> Bool { true }
    func setDefaultBrowser(_ app: BrowserApp) async throws { current = app }
    func open(_ url: URL, with app: BrowserApp) async {}
}
