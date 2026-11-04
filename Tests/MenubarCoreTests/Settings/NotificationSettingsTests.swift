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

    @Test("INBOX-08 the Red Dot toggle changes the Red Dot only and the choice decides the Inbox; the default removes the override")
    func togglesKeepTheOtherRoute() {
        var rules = InboxNotificationRules()
        #expect(rules.sends(.assigned, to: .inbox) && rules.sends(.assigned, to: .badge))

        rules.set(.badge, false, for: .assigned)
        #expect(rules.routes(for: .assigned) == [.inbox])

        rules.set(.off, for: .claudeAnswered)
        #expect(rules.routes(for: .claudeAnswered) == [.badge])
        // The Inbox bit isn't a toggle any more: setting it does nothing.
        rules.set(.inbox, false, for: .digestReady)
        #expect(rules.routes(for: .digestReady) == [.inbox, .badge])

        rules.set(.badge, true, for: .assigned)
        #expect(rules.overrides["assigned"] == nil)
        // The successful builds don't count by default, and the default removes the override.
        #expect(rules.routes(for: .buildSucceeded) == [.inbox])
        rules.set(.badge, true, for: .buildSucceeded)
        #expect(rules.routes(for: .buildSucceeded) == [.inbox, .badge])
        rules.set(.badge, false, for: .buildSucceeded)
        #expect(rules.overrides["buildSucceeded"] == nil)
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
        // Bits 1 and 2 only: the Red Dot (4) is off. The Inbox bit is the migration's to read (ALERT-14).
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

    @Test("INBOX-08 the log line names what differs from the defaults and the filter, and holds no title or token")
    func summaryLine() {
        var rules = InboxNotificationRules()
        #expect(rules.summary == "coffee break at 08:59")
        rules.set(.badge, false, for: .otherTodo)
        rules.set(.off, for: .buildSucceeded)
        rules.onlyMyProjects = true
        #expect(
            rules.summary
                == "delivery: My Jenkins Build Succeeded → Off; red dot changed: Other To-Dos; only my projects; coffee break at 08:59")
    }
}
