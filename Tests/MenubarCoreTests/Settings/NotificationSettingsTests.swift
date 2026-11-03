import Foundation
import Testing

@testable import MenubarCore

/// What Settings → Notifications edits of the Inbox's routing (INBOX-08).
@Suite("Inbox notification settings")
struct NotificationSettingsTests {
    private static func event(_ kind: InboxEventKind) -> InboxEvent {
        InboxEvent(
            id: "e|\(kind.rawValue)", kind: kind, source: .mergeRequests, title: "Fix the cache",
            reference: "group/project!12", projectPath: "group/project", occurredAt: Date(timeIntervalSince1970: 0))
    }

    @Test("INBOX-08 the toggles change one route of a kind and keep the other; the default removes the override")
    func togglesKeepTheOtherRoute() {
        var rules = InboxNotificationRules()
        #expect(rules.sends(.assigned, to: .inbox) && rules.sends(.assigned, to: .badge))

        rules.set(.badge, false, for: .assigned)
        #expect(rules.routes(for: .assigned) == [.inbox])

        rules.set(.inbox, false, for: .claudeAnswered)
        #expect(rules.routes(for: .claudeAnswered) == [.badge])

        rules.set(.badge, true, for: .assigned)
        #expect(rules.overrides["assigned"] == nil)
    }

    @Test("INBOX-08 every kind Settings lists is listed once, and none goes to a macOS banner")
    func kindsAreListedOnce() {
        #expect(Set(InboxNotificationRules.settingsKinds) == Set(InboxEventKind.allCases))
        #expect(InboxNotificationRules.settingsKinds.count == InboxEventKind.allCases.count)
        // A value saved when the app still had banners (bit 1) reads as without it.
        let old = InboxNotificationRules(overrides: ["assigned": InboxRoutes(rawValue: 7)])
        #expect(old.routes(for: .assigned) == [.inbox, .badge])
        let event = Self.event(.assigned)
        #expect(InboxNotificationRules().route(event, myProjects: []) == [.inbox, .badge])
    }

    @Test("INBOX-08 files saved with quiet hours and the sound still load")
    func oldFilesLoad() throws {
        let text = #"{"overrides":{"mentioned":3},"quietHours":{"startMinute":1140,"endMinute":480},"onlyMyProjects":true,"playsSound":true}"#
        let rules = try JSONDecoder().decode(InboxNotificationRules.self, from: Data(text.utf8))
        #expect(rules.routes(for: .mentioned) == [.inbox])
        #expect(rules.onlyMyProjects)
    }

    @Test("INBOX-08 the routing survives a backup: its key is allowlisted and round-trips")
    func routingIsInTheBackup() throws {
        #expect(PersonalSettingsBackup.allowlist.contains(PersonalSettingsBackup.Entry(PreferencesStore.inboxNotificationsKey, .string)))

        let source = TemporaryDefaults()
        var rules = InboxNotificationRules()
        rules.set(.badge, false, for: .mentioned)
        rules.onlyMyProjects = true
        PreferencesStore(defaults: source.defaults).save(Preferences(inboxNotifications: rules))
        let data = try PersonalSettingsBackup.export(from: source.defaults)

        let target = TemporaryDefaults()
        _ = try PersonalSettingsBackup.importValues(from: data, into: target.defaults)
        #expect(PreferencesStore(defaults: target.defaults).load().inboxNotifications == rules)
    }

    @Test("INBOX-08 the log line names what is off and the filter, and holds no title or token")
    func summaryLine() {
        var rules = InboxNotificationRules()
        #expect(rules.summary == "coffee break at 08:59")
        rules.set(.badge, false, for: .otherTodo)
        rules.onlyMyProjects = true
        #expect(rules.summary == "not in the badge: Other To-Dos; only my projects; coffee break at 08:59")
    }
}
