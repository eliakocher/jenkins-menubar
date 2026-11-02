import Foundation
import Testing

@testable import MenubarCore

/// Open at login with `FakeLoginItem`. The real `SMAppService` is never touched: registering it would add a login item
/// to the Mac running the tests.
@Suite("LaunchAtLogin")
@MainActor
struct LoginItemTests {
    @Test("APP-02 turns open at login on and off")
    func turnsOnAndOff() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let item = FakeLoginItem()
        let launchAtLogin = LaunchAtLogin(item: item, log: log)

        #expect(try await launchAtLogin.setOn(true) == .enabled)
        #expect(launchAtLogin.status.isOn)
        // Asking for what already is changes nothing and logs nothing.
        #expect(try await launchAtLogin.setOn(true) == .enabled)
        #expect(try await launchAtLogin.setOn(false) == .notRegistered)
        #expect(!launchAtLogin.status.isOn)

        #expect(item.calls == [.register, .unregister])
        #expect(await log.entries().map(\.message) == ["openAtLogin: off → on", "openAtLogin: on → off"])
        #expect(await log.entries().allSatisfy { $0.level == .info && $0.source == .settings })
    }

    @Test("APP-07 registers the login item again for the new bundle path when install.sh left the marker")
    func refreshesWhenMarked() async throws {
        let folder = try TemporaryFolder()
        let item = FakeLoginItem(status: .enabled)
        let launchAtLogin = LaunchAtLogin(item: item)

        // No marker: nothing happens, so a login item the user turned on or off stays as it is.
        await launchAtLogin.refreshRegistrationIfMarked(in: folder.url)
        #expect(item.calls.isEmpty)

        _ = try folder.write("", to: LaunchAtLogin.refreshMarkerName)
        await launchAtLogin.refreshRegistrationIfMarked(in: folder.url)
        #expect(item.calls == [.unregister, .register])
        #expect(item.status == .enabled)

        // The marker is gone, so the next launch leaves it alone.
        await launchAtLogin.refreshRegistrationIfMarked(in: folder.url)
        #expect(item.calls == [.unregister, .register])
    }

    @Test("APP-02 a refused registration says why and stays off")
    func refusedRegistration() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let item = FakeLoginItem()
        item.error = NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let launchAtLogin = LaunchAtLogin(item: item, log: log)

        await #expect(throws: LoginItemError(turningOn: true, reason: "Operation not permitted")) {
            try await launchAtLogin.setOn(true)
        }

        #expect(launchAtLogin.status == .notRegistered)
        #expect(await log.entries().map(\.level) == [.warning])
    }
}
