import Foundation
import Testing

@testable import MenubarCore

@Suite("Hot corners alert mute")
@MainActor
struct HotCornerAlertMuteTests {
    /// a time that moves only when the test says
    private final class Now: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_792_800_000)

        var date: Date { lock.withLock { value } }

        func wait(_ seconds: TimeInterval) {
            lock.withLock { value += seconds }
        }
    }

    @Test("HOT-09 Mute Alerts lasts an hour, fired again it ends the mute, and each change is logged")
    func muteWindow() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let now = Now()
        let clock = TestClock()
        let mute = AlertMute(now: { now.date }, clock: clock, log: log)
        #expect(!mute.isMuted)

        #expect(mute.toggle())
        #expect(mute.isMuted)
        #expect(mute.until == now.date.addingTimeInterval(3600))
        now.wait(3599)
        #expect(mute.isMuted)
        #expect(!mute.toggle())
        #expect(!mute.isMuted && mute.until == nil)

        // Muted again, the hour runs out by itself.
        mute.toggle()
        await clock.waitForSleepers()
        now.wait(3600)
        clock.advance(by: .seconds(3600))
        for _ in 0..<1000 where mute.until != nil {
            await Task.yield()
        }
        #expect(mute.until == nil && !mute.isMuted)

        await mute.settled()
        let lines = await log.entries().map(\.message)
        #expect(lines.count == 4)
        #expect(lines.filter { $0.hasPrefix("Alerts muted until") }.count == 2)
        #expect(lines[1] == "Alerts unmuted" && lines[3] == "Alerts unmuted: the hour is over")
    }

    @Test("HOT-09 while muted, the Inbox's panels and banners stay quiet and the events stay in the Inbox, with a log line")
    func inboxStaysQuiet() async throws {
        let folder = try TemporaryFolder()
        let defaults = TemporaryDefaults()
        let effects = FakeEffects()
        let model = AppModel(dependencies: .fake(root: folder.url, defaults: defaults.defaults, effects: effects))
        let date = Date(timeIntervalSince1970: 1_792_800_000)
        let panel = InboxEvent(id: "a", kind: .approved, source: .todo, title: "Item", occurredAt: date)
        let banner = InboxEvent(id: "b", kind: .mentioned, source: .todo, title: "Item", occurredAt: date)
        let routed = [
            RoutedInboxEvent(event: panel, routes: [.inbox, .badge], delivery: .bigPanel),
            RoutedInboxEvent(event: banner, routes: [.inbox, .badge], delivery: .desktopNotification),
        ]

        #expect(model.toggleMuteAlerts())
        await model.deliver(routed)
        #expect(await effects.inboxPanels.isEmpty)
        #expect(await effects.inboxBanners.isEmpty)
        let lines = await model.log.entries().map(\.message)
        #expect(lines.filter { $0.hasPrefix("Inbox: alerts are muted") }.count == 2)

        #expect(!model.toggleMuteAlerts())
        await model.deliver(routed)
        #expect(await effects.inboxPanels.map(\.id) == ["a"])
        #expect(await effects.inboxBanners.map(\.id) == ["b"])
    }
}
