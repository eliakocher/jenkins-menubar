import Foundation
import Testing

@testable import MenubarCore

/// The coffee break can't be snoozed, anywhere (the user, 2026-11-03: "coffee is mandatory").
@Suite("CoffeeSnooze", .timeLimit(.minutes(1)))
@MainActor
struct CoffeeSnoozeTests {
    @Test("INBOX-14 only the coffee break can't be snoozed", arguments: InboxEventKind.allCases)
    func rule(_ kind: InboxEventKind) {
        #expect(kind.canSnooze == (kind != .coffeeBreak))
    }

    @Test("INBOX-14 the coffee break's panel says On My Way and its banner has no Snooze")
    func panelAndBanner() throws {
        let coffee = InboxEvent.coffeeBreak(line: "Warm cups, cold pipelines.", at: Date(timeIntervalSince1970: 1_793_613_600))
        #expect(InboxDeliveryAction.done.panelTitle(for: .coffeeBreak) == "On My Way ☕")
        #expect(InboxDeliveryAction.done.panelTitle(for: .mentioned) == "Done")
        #expect(InboxDeliveryAction.dismiss.panelTitle(for: .coffeeBreak) == "Dismiss")
        #expect(InboxBanner.category(for: coffee) == InboxBanner.coffeeCategory)
        #expect(InboxBanner.coffeeActions == [.done])
        #expect(InboxEntry(event: coffee).canSnooze == false)
    }

    @Test("INBOX-04 snoozing the coffee break does nothing, and it stays pending")
    func storeRefuses() async throws {
        let folder = try TemporaryFolder()
        let team = TeamStore(folder: folder.file("support"), report: { _ in })
        let services = GitLabServices(
            transport: StubTransport(), clock: ContinuousClock(), tokens: TokenStore(keychain: InMemoryKeychain(values: [:])),
            team: team, caches: CacheStore(folder: folder.file("caches"), report: { _ in }),
            log: ActivityLog(folder: folder.file("logs")))
        let store = InboxStore(services: services, folder: folder.file("support"), rules: InboxNotificationRules(), myProjects: { [] })
        let now = services.now()
        store.addLocal(.coffeeBreak(line: "Warm cups, cold pipelines.", at: now))
        let entry = try #require(store.pending.first)
        #expect(entry.kind == .coffeeBreak)

        await store.snooze(entry, .oneHour)

        #expect(store.pending.map(\.id) == [entry.id])
        #expect(store.snoozed.isEmpty)

        // Done still works.
        await store.markDone(entry)
        #expect(store.pending.isEmpty && store.done.map(\.id) == [entry.id])
    }
}
