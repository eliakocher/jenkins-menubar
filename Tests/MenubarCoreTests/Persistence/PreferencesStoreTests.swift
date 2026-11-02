import Foundation
import Testing

@testable import MenubarCore

@Suite("PreferencesStore")
struct PreferencesStoreTests {
    @Test("SET-01 a value outside the options counts as the default")
    func outsideTheOptions() {
        let suite = TemporaryDefaults()
        let values: [PreferencesStore.Key: Any] = [
            .checkIntervalSeconds: 45,
            .hideSuccessfulAfter: "5",
            .hideFailedAfter: "0",
            .hidesMergedBuilds: "off",
            .alertStyle: "dialog",
            .stageAlerts: 3,
            .iconStyle: "emoji",
            .gitLabMaxAgeSeconds: "30",
            .workItemsScope: "everyone",
            .workItemsType: "issue",
            .workItemsState: "open",
            .workItemsSort: "NAME_ASC",
            .workItemsLimit: 25,
            .workItemsWithLabels: "bug,web",
            .workItemsWithoutLabels: [1, 2],
            .workItemsLabelsMatch: "some",
            .workItemsHideOnRows: "group:, affects::",
            .workItemsScopedValueOnly: "yes",
            .showInMenuBar: "off",
            .fillInCopiedLink: "yes",
            .globalShortcut: "⌘K",
            .easterEggs: "off",
            .slotAlerts: "on",
        ]
        #expect(Set(values.keys) == Set(PreferencesStore.Key.allCases))
        for (key, value) in values {
            suite.defaults.set(value, forKey: key.rawValue)
        }

        #expect(PreferencesStore(defaults: suite.defaults).load() == Preferences())

        // Saving such a value writes the default as well.
        let other = TemporaryDefaults()
        let store = PreferencesStore(defaults: other.defaults)
        #expect(store.save(Preferences(checkIntervalSeconds: 45, hideSuccessfulAfter: .hours(2))).isEmpty)
        #expect(store.load() == Preferences())
    }

    @Test("SET-01 changes are saved")
    func changesAreSaved() {
        let suite = TemporaryDefaults()
        let store = PreferencesStore(defaults: suite.defaults)
        let changed = Preferences(
            checkIntervalSeconds: 300, hideSuccessfulAfter: .immediately, hideFailedAfter: .never, hidesMergedBuilds: false,
            alertStyle: .banner, stageAlerts: false, iconStyle: .color, gitLabMaxAgeSeconds: 120,
            workItems: WorkItemFilters(
                scope: .authored, type: .epic, state: .all, sort: .dueDate, limit: 100,
                withLabels: ["status::InProgress", "evil::$(touch pwned)"], withoutLabels: ["a|b"], labelsMatch: .any),
            workItemRows: WorkItemRowLabels(hidden: ["group:", "affects::"], showsScopedValueOnly: true),
            showInMenuBar: false, fillInCopiedLink: true,
            globalShortcut: HotkeyShortcut(keyCode: 40, modifiers: [.command], label: "K"), easterEggs: false,
            slotAlerts: true)

        let changes = store.save(changed)

        #expect(PreferencesStore(defaults: suite.defaults).load() == changed)
        #expect(changes.map(\.key) == PreferencesStore.Key.allCases)
        #expect(changes.first == PreferencesStore.Change(key: .checkIntervalSeconds, old: "60", new: "300"))
        #expect(changes.contains(PreferencesStore.Change(key: .hideFailedAfter, old: "168", new: "never")))
        #expect(changes.contains(PreferencesStore.Change(key: .hidesMergedBuilds, old: "on", new: "off")))
        #expect(changes.contains(PreferencesStore.Change(
            key: .workItemsWithLabels, old: "", new: "status::InProgress, evil::$(touch pwned)")))
        #expect(store.save(changed).isEmpty)

        // Only the values that changed are written and reported.
        let fresh = TemporaryDefaults()
        let freshStore = PreferencesStore(defaults: fresh.defaults)
        var preferences = freshStore.load()
        preferences.alertStyle = .banner
        #expect(freshStore.save(preferences) == [PreferencesStore.Change(key: .alertStyle, old: "window", new: "banner")])
        #expect(fresh.defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("workItems") }.isEmpty)
        #expect(fresh.defaults.string(forKey: "alertStyle") == "banner")
    }

    @Test("SET-01 a preferences value encoded before showInMenuBar and fillInCopiedLink decodes with their defaults")
    func decodesAnOlderValue() throws {
        var json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences(checkIntervalSeconds: 300)))
                as? [String: Any])
        json["showInMenuBar"] = nil
        json["fillInCopiedLink"] = nil
        // Stored before ALERT-04 was dropped.
        json["speaksResult"] = true

        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: json))

        #expect(decoded == Preferences(checkIntervalSeconds: 300))
        #expect(decoded.showInMenuBar)
        #expect(!decoded.fillInCopiedLink)
        #expect(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)) == Preferences())
    }

    @Test("hiding after N hours hides only once more than N hours have passed")
    func hideAfter() {
        #expect(Preferences.HideAfter.immediately.hides(finishedFor: 0))
        #expect(!Preferences.HideAfter.hours(1).hides(finishedFor: 3600))
        #expect(Preferences.HideAfter.hours(1).hides(finishedFor: 3601))
        #expect(!Preferences.HideAfter.never.hides(finishedFor: 1e9))
        #expect(Preferences.HideAfter(rawValue: "024") == nil)
        #expect(Preferences.HideAfter(rawValue: "-1") == nil)
    }
}
