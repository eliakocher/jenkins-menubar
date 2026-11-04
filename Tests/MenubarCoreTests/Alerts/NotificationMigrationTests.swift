import Foundation
import Testing

@testable import MenubarCore

/// The one-time move from the build alert style, the stage banners, the group switches and the Inbox toggles to the table.
@Suite("NotificationMigration")
struct NotificationMigrationTests {
    private static func old(
        style: String?, mine: Bool = true, watching: Bool = true, rules: InboxNotificationRules = InboxNotificationRules()
    ) -> InboxNotificationRules {
        NotificationMigration.migrated(rules: rules, alertStyle: style, mine: mine, watching: watching)
    }

    // MARK: ALERT-14

    @Test(
        "ALERT-14 the old alert style becomes my two rows: a window is a Pop-up, a banner a Banner, Inbox Only is Inbox and Off",
        arguments: [
            (nil, InboxDelivery.popUp, InboxDelivery.popUp),
            ("window", .popUp, .popUp),
            ("banner", .banner, .banner),
            ("inboxOnly", .inbox, .off),
            ("something else", .popUp, .popUp),
        ] as [(String?, InboxDelivery, InboxDelivery)])
    func alertStyle(style: String?, failed: InboxDelivery, succeeded: InboxDelivery) {
        let rules = Self.old(style: style)

        #expect(rules.delivery(for: .buildFailed) == failed)
        #expect(rules.delivery(for: .buildSucceeded) == succeeded)
        // The watched rows get their defaults.
        #expect(rules.delivery(for: .watchedBuildFailed) == .banner)
        #expect(rules.delivery(for: .watchedBuildSucceeded) == .banner)
    }

    @Test(
        "ALERT-14 a switch that was off turns its rows Off: Watching off is the watched rows, My Builds off is mine",
        arguments: [(true, false), (false, true), (false, false), (true, true)])
    func groupSwitches(mine: Bool, watching: Bool) {
        let rules = Self.old(style: "window", mine: mine, watching: watching)

        #expect((rules.delivery(for: .buildFailed) == .off) == !mine)
        #expect((rules.delivery(for: .buildSucceeded) == .off) == !mine)
        #expect((rules.delivery(for: .watchedBuildFailed) == .off) == !watching)
        #expect((rules.delivery(for: .watchedBuildSucceeded) == .off) == !watching)
    }

    @Test("ALERT-14 an Inbox toggle that was off with nothing announcing is Off; a pop-up the user chose stays; the Red Dot stays")
    func perKind() throws {
        // As the old app wrote them: the Inbox bit (2) and the badge bit (4), and the old delivery names.
        let text = """
            {"overrides":{"mentioned":4,"assigned":2,"claudeAnswered":0,"digestReady":4,"approved":6,"buildFailed":0},
            "deliveries":{"digestReady":"bigPanel","reviewRequested":"desktopNotification","buildFailed":"desktopNotification"}}
            """
        let legacy = try JSONDecoder().decode(InboxNotificationRules.self, from: Data(text.utf8))

        let rules = Self.old(style: "window", rules: legacy)

        // Inbox off, nothing announcing: Off. Its Red Dot setting is kept as it was.
        #expect(rules.delivery(for: .mentioned) == .off)
        #expect(rules.delivery(for: .claudeAnswered) == .off)
        // Inbox off but a pop-up chosen: the pop-up stays, and an entry comes with it now.
        #expect(rules.delivery(for: .digestReady) == .popUp)
        // Inbox on: as before; a banner choice stays.
        #expect(rules.delivery(for: .assigned) == .inbox)
        #expect(rules.delivery(for: .approved) == .inbox)
        #expect(rules.delivery(for: .reviewRequested) == .banner)
        // The Red Dot: mentioned counted, assigned didn't, claudeAnswered didn't, digestReady counted.
        #expect(rules.sends(.mentioned, to: .badge))
        #expect(!rules.sends(.assigned, to: .badge))
        #expect(!rules.sends(.claudeAnswered, to: .badge))
        #expect(rules.sends(.digestReady, to: .badge))
        // A failed build's old Inbox delivery is the alert style now, never the stale choice.
        #expect(rules.delivery(for: .buildFailed) == .popUp)
        #expect(!rules.sends(.buildFailed, to: .badge))
        // The Inbox bit is gone from what is kept: the Inbox is the delivery's.
        #expect(rules.overrides.values.allSatisfy { !$0.contains(.inbox) })
    }

    @Test("ALERT-14 a failed build that was Inbox Only with the Inbox off is Off, one that popped up keeps its pop-up")
    func failedBuildInboxOff() throws {
        let legacy = try JSONDecoder().decode(
            InboxNotificationRules.self, from: Data(#"{"overrides":{"buildFailed":4}}"#.utf8))

        #expect(Self.old(style: "inboxOnly", rules: legacy).delivery(for: .buildFailed) == .off)
        #expect(Self.old(style: "banner", rules: legacy).delivery(for: .buildFailed) == .banner)
    }

    @Test("ALERT-14 GitLab's pipeline failed is Off after the move, unless the user chose a delivery for it")
    func pipelineFailedIsOff() throws {
        #expect(Self.old(style: "window").delivery(for: .pipelineFailed) == .off)
        let chosen = try JSONDecoder().decode(
            InboxNotificationRules.self, from: Data(#"{"deliveries":{"pipelineFailed":"desktopNotification"}}"#.utf8))
        #expect(Self.old(style: "window", rules: chosen).delivery(for: .pipelineFailed) == .banner)
    }

    @Test("ALERT-14 the policy's two switches are read from the old text, the jobs stay")
    func policySwitches() {
        #expect(NotificationMigration.groupSwitches(inPolicyText: nil) == (true, true))
        #expect(NotificationMigration.groupSwitches(inPolicyText: "not json") == (true, true))
        #expect(NotificationMigration.groupSwitches(inPolicyText: #"{"watching":false,"jobs":{"MR-1":"never"}}"#) == (true, false))
        #expect(NotificationMigration.groupSwitches(inPolicyText: #"{"mine":false}"#) == (false, true))
    }

    @Test("ALERT-14 a saved preferences file moves once on load, keeps the old keys readable, and the new choices are not moved again")
    func storeMigratesOnce() throws {
        let suite = TemporaryDefaults()
        suite.defaults.set("inboxOnly", forKey: "alertStyle")
        suite.defaults.set(false, forKey: "stageAlerts")
        suite.defaults.set(
            #"{"mine":true,"watching":false,"jobs":{"MR-1":"never"}}"#, forKey: PreferencesStore.notificationPolicyKey)
        suite.defaults.set(#"{"overrides":{"mentioned":4}}"#, forKey: PreferencesStore.inboxNotificationsKey)
        let store = PreferencesStore(defaults: suite.defaults)

        let loaded = store.load()

        let rules = loaded.inboxNotifications
        #expect(rules.delivery(for: .buildFailed) == .inbox)
        #expect(rules.delivery(for: .buildSucceeded) == .off)
        #expect(rules.delivery(for: .watchedBuildFailed) == .off)
        #expect(rules.delivery(for: .mentioned) == .off)
        // The policy keeps its jobs; the old keys are still there to read.
        #expect(store.notificationPolicy == NotificationPolicy(jobs: ["MR-1": .never]))
        let policyText = try #require(suite.defaults.string(forKey: PreferencesStore.notificationPolicyKey))
        #expect(!policyText.contains("watching"))
        #expect(suite.defaults.string(forKey: "alertStyle") == "inboxOnly")
        #expect(suite.defaults.object(forKey: "stageAlerts") as? Bool == false)
        #expect(suite.defaults.integer(forKey: NotificationMigration.versionKey) == NotificationMigration.version)

        // Moved once: a later choice, even one equal to a default, and the old key changing don't move anything again.
        var preferences = loaded
        preferences.inboxNotifications.set(.popUp, for: .buildFailed)
        preferences.inboxNotifications.set(.banner, for: .watchedBuildFailed)
        store.save(preferences)
        suite.defaults.set("banner", forKey: "alertStyle")
        let again = PreferencesStore(defaults: suite.defaults).load().inboxNotifications
        #expect(again.delivery(for: .buildFailed) == .popUp)
        #expect(again.delivery(for: .watchedBuildFailed) == .banner)
        #expect(again.delivery(for: .mentioned) == .off)
    }

    @Test("ALERT-14 a fresh install migrates to the defaults and writes nothing but the version")
    func freshInstall() {
        let suite = TemporaryDefaults()

        let loaded = PreferencesStore(defaults: suite.defaults).load()

        #expect(loaded.inboxNotifications == InboxNotificationRules())
        #expect(suite.defaults.object(forKey: PreferencesStore.inboxNotificationsKey) == nil)
        #expect(suite.defaults.object(forKey: PreferencesStore.notificationPolicyKey) == nil)
    }

    @Test("ALERT-14 a backup from before the single table migrates when it is imported, whatever this Mac had")
    func oldBackupMigrates() throws {
        // This Mac has migrated already and has its own choices.
        let target = TemporaryDefaults()
        let store = PreferencesStore(defaults: target.defaults)
        var preferences = store.load()
        preferences.inboxNotifications.set(.off, for: .coffeeBreak)
        store.save(preferences)
        let backup = """
            {"formatVersion":1,"kind":"megamonitor-personal-settings","exportedAt":"2026-11-01T10:00:00Z",
            "values":{"alertStyle":"banner","stageAlerts":true,"notificationPolicy":"{\\"jobs\\":{},\\"watching\\":false}"}}
            """

        try PersonalSettingsBackup.importValues(from: Data(backup.utf8), into: target.defaults)

        let rules = PreferencesStore(defaults: target.defaults).load().inboxNotifications
        #expect(rules.delivery(for: .buildFailed) == .banner)
        #expect(rules.delivery(for: .watchedBuildFailed) == .off)
        // What the old file doesn't hold is at its default.
        #expect(rules.delivery(for: .coffeeBreak) == .inbox)
    }

    @Test("ALERT-14 the backup allowlist holds the table, the jobs and the version, and no secret")
    func backupAllowlist() {
        let keys = Set(PersonalSettingsBackup.allowlist.map(\.key))

        #expect(keys.isSuperset(of: [
            PreferencesStore.inboxNotificationsKey, PreferencesStore.notificationPolicyKey, NotificationMigration.versionKey,
        ]))
        // The new preferences have no key for the removed settings.
        #expect(PreferencesStore.Key.allCases.map(\.rawValue).allSatisfy { $0 != "alertStyle" && $0 != "stageAlerts" })
    }
}
