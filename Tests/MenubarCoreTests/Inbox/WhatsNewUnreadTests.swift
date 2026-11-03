import Foundation
import Testing

@testable import MenubarCore

/// The "What's New" entry while it waits unread, which the Inbox shows as its hero card (INBOX/WHATSNEW).
@Suite("What's New unread", .timeLimit(.minutes(1)))
@MainActor
struct WhatsNewUnreadTests {
    private nonisolated static let start = Date(timeIntervalSince1970: 1_793_610_000)

    private static func entry(_ version: String = "1.0.5") -> WhatsNewEntry {
        WhatsNewEntry(
            version: version, from: "1.0.4",
            sections: [ChangelogSection(version: version, date: nil, body: "### Added\n- Pipelines:\n  - **Watch** a job.\n- Slots `keys`.")])
    }

    private static func model(folder: TemporaryFolder, defaults: TemporaryDefaults) throws -> AppModel {
        try TeamStore(folder: FileLocations(root: folder.url).applicationSupport, report: { _ in })
            .save(Project(id: .main, team: TeamValues(
                jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: "https://gitlab.example.com",
                gitLabProject: "acme/web/app")))
        return AppModel(
            dependencies: .fake(
                root: folder.url, defaults: defaults.defaults, now: { start }, effects: FakeEffects(notificationsAllowed: true),
                processRunner: ScriptedClaude([.failure])))
    }

    @Test("INBOX/WHATSNEW the entry is unread while pending and not opened; opening it, Done and another kind end it")
    func unreadState() async throws {
        let folder = try TemporaryFolder()
        let defaults = TemporaryDefaults()
        let store = try Self.model(folder: folder, defaults: defaults).inbox
        #expect(store.unreadWhatsNew == nil)

        store.addLocal(.whatsNew(Self.entry(), at: Self.start))
        let unread = try #require(store.unreadWhatsNew)
        #expect(unread.id == "whatsnew|1.0.5")

        // Opened: the hero ends, the row stays pending as an ordinary one.
        store.seen.markSeen(unread.id)
        #expect(store.unreadWhatsNew == nil)
        #expect(store.pending.contains { $0.id == unread.id })

        // Seen again as new, then Done.
        store.seen.markUnseen(unread.id)
        #expect(store.unreadWhatsNew != nil)
        await store.markDone(unread)
        #expect(store.unreadWhatsNew == nil)
    }

    @Test("INBOX/WHATSNEW the hero's lines are the first changes of the newest version, without marks or list introductions")
    func highlights() {
        let entry = Self.entry()
        #expect(WhatsNew.highlights(of: entry.sections, limit: 3) == ["Watch a job.", "Slots keys."])
        #expect(WhatsNew.highlights(of: entry.sections, limit: 1) == ["Watch a job."])
        #expect(WhatsNew.highlights(of: [], limit: 3).isEmpty)
    }
}
