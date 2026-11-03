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

    @Test("APP-02 the status line names the likely cause when macOS can't find the app", arguments: [
        (LoginItemPlace(bundlePath: "/private/var/folders/x/T/AppTranslocation/A/d/MegaMonitor.app", isQuarantined: false, home: "/Users/me"),
         LoginItemHelp.quarantined),
        (LoginItemPlace(bundlePath: "/Users/me/Applications/MegaMonitor.app", isQuarantined: true, home: "/Users/me"),
         LoginItemHelp.quarantined),
        (LoginItemPlace(bundlePath: "/Users/me/Downloads/MegaMonitor.app", isQuarantined: false, home: "/Users/me"),
         "MegaMonitor runs from ~/Downloads, not from an Applications folder. Move it to ~/Applications "
            + "(or install it with ./install.sh), then open it again."),
        (LoginItemPlace(bundlePath: "/Users/me/Applications/MegaMonitor.app", isQuarantined: false, home: "/Users/me"),
         LoginItemHelp.unknownCause),
    ])
    func namesTheCause(place: LoginItemPlace, text: String) {
        let help = LoginItemHelp.of(status: .notFound, place: place, failed: false)
        #expect(help.message == text)
        #expect(help.opensLoginItems)
        // A refusal that leaves the item not registered gets the same help.
        #expect(LoginItemHelp.of(status: .notRegistered, place: place, failed: true).message == text)
        // Nothing to say while it is just off, and the approval line keeps its button.
        #expect(LoginItemHelp.of(status: .notRegistered, place: place, failed: false).message == nil)
        #expect(LoginItemHelp.of(status: .enabled, place: place, failed: false).message == nil)
        #expect(LoginItemHelp.of(status: .requiresApproval, place: place, failed: false).opensLoginItems)
    }

    @Test("APP-02 a login item macOS can't find is still registered, and a refusal logs status and place once")
    func notFoundIsTried() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let item = FakeLoginItem(status: .notFound)
        item.place = LoginItemPlace(bundlePath: "/Users/me/Downloads/MegaMonitor.app", isQuarantined: true, home: "/Users/me")
        item.error = NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let launchAtLogin = LaunchAtLogin(item: item, log: log)

        await #expect(throws: LoginItemError.self) { try await launchAtLogin.setOn(true) }

        #expect(item.calls == [.register])
        let entries = await log.entries()
        #expect(entries.count == 1)
        #expect(entries[0].message.contains("status notFound"))
        #expect(entries[0].message.contains("/Users/me/Downloads/MegaMonitor.app"))

        // Once registering works, the status afterwards is the truth.
        item.error = nil
        #expect(try await launchAtLogin.setOn(true) == .enabled)
    }
}
