import Foundation
import Testing

@testable import MenubarCore

/// The "What's New" entry after an update: the changelog's parsing, which versions to show, and the entry itself.
@Suite("What's New", .timeLimit(.minutes(1)))
struct WhatsNewTests {
    private static let file = """
        # Changelog

        All notable changes.

        ## [Unreleased]

        ### Added
        - Not released yet.

        ## [1.0.2] - 2026-11-02

        ### Fixed
        - Two.

        ## [1.0.10] - 2026-11-20

        ### Added
        - **Ten:** the tenth.

        ## [1.0.9]

        ### Changed
        - Nine.

        [1.0.9]: https://example.com/compare/1.0.8...1.0.9
        """

    private static let sections = Changelog.parse(file)

    @Test("WHATSNEW-01 the changelog's sections are read newest first, without Unreleased, link lines and the intro")
    func parsing() {
        #expect(Self.sections.map(\.version) == ["1.0.10", "1.0.9", "1.0.2"])
        #expect(Self.sections[0].date == "2026-11-20")
        #expect(Self.sections[1].date == nil)
        #expect(Self.sections[1].body == "### Changed\n- Nine.")
        #expect(!Self.sections.map(\.body).joined().contains("Not released"))
        #expect(Changelog.parse("no sections here").isEmpty)
    }

    @Test("WHATSNEW-01 versions compare number by number")
    func versions() throws {
        #expect(try #require(VersionNumber("1.0.10")) > #require(VersionNumber("1.0.9")))
        #expect(try #require(VersionNumber("1.0")) == #require(VersionNumber("1.0.0")))
        #expect(try #require(VersionNumber("1.0.4-beta")) == #require(VersionNumber("1.0.4")))
        #expect(VersionNumber("Unreleased") == nil)
        #expect(VersionNumber("") == nil)
    }

    @Test(
        "WHATSNEW-02 an update shows every version after the last seen one, up to the launched one",
        arguments: [
            // last seen, launched, the versions shown
            ("1.0.9", "1.0.10", ["1.0.10"]),
            ("1.0.2", "1.0.10", ["1.0.10", "1.0.9"]),
            ("1.0.1", "1.0.9", ["1.0.9", "1.0.2"]),
            // The changelog has no section for the launched version: what's after the last seen one up to it shows.
            ("1.0.2", "1.0.5", []),
        ])
    func update(lastSeen: String, launched: String, shown: [String]) {
        let decision = WhatsNew.decide(current: launched, lastSeen: lastSeen, isFreshInstall: false, changelog: Self.sections)
        #expect(decision.entry?.sections.map(\.version) ?? [] == shown)
        #expect(decision.entry?.from == (shown.isEmpty ? nil : lastSeen))
        #expect(decision.seen == launched)
    }

    @Test("WHATSNEW-03 a fresh install shows nothing and remembers the version")
    func freshInstall() {
        let decision = WhatsNew.decide(current: "1.0.10", lastSeen: nil, isFreshInstall: true, changelog: Self.sections)
        #expect(decision == WhatsNew.Decision(entry: nil, seen: "1.0.10"))
    }

    @Test("WHATSNEW-03 an install that kept no version yet shows the launched version's own section")
    func existingInstallWithoutVersion() {
        let decision = WhatsNew.decide(current: "1.0.10", lastSeen: nil, isFreshInstall: false, changelog: Self.sections)
        #expect(decision.entry?.sections.map(\.version) == ["1.0.10"])
        #expect(decision.entry?.from == "1.0.9")
        #expect(decision.seen == "1.0.10")
        let oldest = WhatsNew.decide(current: "1.0.2", lastSeen: nil, isFreshInstall: false, changelog: Self.sections)
        #expect(oldest.entry?.sections.map(\.version) == ["1.0.2"])
        #expect(oldest.entry?.from == nil)
    }

    @Test(
        "WHATSNEW-03 the same version, an older one or an unreadable one shows nothing and keeps the newest seen",
        arguments: [("1.0.10", "1.0.10"), ("1.0.10", "1.0.9"), ("1.0.10", "dev")])
    func nothingNew(lastSeen: String, launched: String) {
        let decision = WhatsNew.decide(current: launched, lastSeen: lastSeen, isFreshInstall: false, changelog: Self.sections)
        #expect(decision == WhatsNew.Decision(entry: nil, seen: nil))
    }

    @Test("WHATSNEW-03 no changelog in the bundle shows nothing and doesn't crash")
    func missingChangelog() {
        let decision = WhatsNew.decide(current: "1.0.10", lastSeen: "1.0.9", isFreshInstall: false, changelog: [])
        #expect(decision == WhatsNew.Decision(entry: nil, seen: "1.0.10"))
        #expect(Changelog.bundled(in: Bundle(for: BundleToken.self)).isEmpty)
        #expect(WhatsNew.decide(current: nil, lastSeen: nil, isFreshInstall: true, changelog: []).seen == nil)
    }

    @Test("WHATSNEW-04 the entry is a local one in its own group that opens the versions since the last seen one")
    func entry() throws {
        let decision = WhatsNew.decide(current: "1.0.10", lastSeen: "1.0.2", isFreshInstall: false, changelog: Self.sections)
        let event = InboxEvent.whatsNew(try #require(decision.entry), at: Date(timeIntervalSince1970: 0))
        #expect(event.id == "whatsnew|1.0.10")
        #expect(event.title == "What's new in 1.0.10")
        #expect(event.source == .local)
        #expect(event.kind.group == .whatsNew)
        #expect(event.excerpt == "Ten: the tenth.")
        let route = try #require(event.targetURL.flatMap(AppRoute.init(url:)))
        #expect(route == .whatsNew(from: "1.0.2", to: "1.0.10"))
        #expect(AppRoute(url: AppRoute.whatsNew(from: nil, to: nil).url) == .whatsNew(from: nil, to: nil))
    }

    @Test("WHATSNEW-04 its delivery is Inbox Only until the user picks another, and Settings lists it")
    func delivery() {
        let rules = InboxNotificationRules()
        #expect(rules.delivery(for: .whatsNew) == .inboxOnly)
        #expect(rules.routes(for: .whatsNew).contains(.inbox))
        #expect(InboxNotificationRules.deliveryKinds.contains(.whatsNew))
    }

    @Test("WHATSNEW-02 the last seen version is kept in the preferences")
    func lastSeenVersion() {
        let suite = TemporaryDefaults()
        let store = PreferencesStore(defaults: suite.defaults)
        #expect(store.lastSeenVersion == nil)
        store.lastSeenVersion = "1.0.4"
        #expect(PreferencesStore(defaults: suite.defaults).lastSeenVersion == "1.0.4")
    }

    private final class BundleToken {}
}
