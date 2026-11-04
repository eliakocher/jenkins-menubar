import Foundation
import Testing

@testable import MenubarCore

/// A login item that counts how often macOS is asked.
@MainActor
private final class CountingLoginItem: LoginItem {
    private(set) var statusReads = 0
    private(set) var placeReads = 0

    var status: LoginItemStatus {
        statusReads += 1
        return .enabled
    }

    var place: LoginItemPlace {
        placeReads += 1
        return .installed
    }

    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}

/// Settings reads the login item's status and place when it opens and when the app becomes active, not whenever a view is
/// drawn (APP-02).
@Suite("Login status reads")
@MainActor
struct LoginStatusReadTests {
    @Test("APP-02 the login item is asked once per refresh, however often the status is read")
    func askedOncePerRefresh() throws {
        let folder = try TemporaryFolder()
        let suite = TemporaryDefaults()
        let item = CountingLoginItem()
        let log = ActivityLog(folder: folder.file("Logs"))
        let store = SettingsStore(
            preferences: PreferencesStore(defaults: suite.defaults),
            team: TeamStore(folder: folder.url, report: { _ in }),
            tokens: TokenStore(keychain: InMemoryKeychain(), log: log),
            launchAtLogin: LaunchAtLogin(item: item, log: log),
            log: log,
            transport: { _ in StubTransport() },
            clock: TestClock(),
            checkNow: {},
            setCheckInterval: { _ in })
        #expect((item.statusReads, item.placeReads) == (1, 1))

        // a view reads them as often as it is drawn
        for _ in 0..<20 {
            #expect(store.openAtLogin == .enabled)
            #expect(store.loginItemPlace == .installed)
        }
        #expect((item.statusReads, item.placeReads) == (1, 1))

        store.refreshOpenAtLogin()
        #expect((item.statusReads, item.placeReads) == (2, 2))
    }
}
