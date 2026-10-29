import Foundation
import Testing

@testable import MenubarCore

@Suite("PreferencesStore")
struct PreferencesStoreTests {
    @Test("SET-01 defaults")
    func defaults() {
        let suite = TemporaryDefaults()
        let preferences = PreferencesStore(defaults: suite.defaults).load()

        #expect(preferences.checkIntervalSeconds == 60)
        #expect(preferences.hideSuccessfulAfter == .hours(24))
        #expect(preferences.hideFailedAfter == .hours(168))
        #expect(preferences.hidesMergedBuilds)
        #expect(preferences.alertStyle == .window)
        #expect(preferences.stageAlerts)
        #expect(preferences.iconStyle == .monochrome)
        #expect(preferences.gitLabMaxAgeSeconds == 30)
        #expect(preferences.showInMenuBar)
        #expect(!preferences.fillInCopiedLink)
        #expect(preferences.workItems == WorkItemFilters(
            scope: .assigned, type: .all, state: .opened, sort: .recentlyUpdated, limit: 20, withLabels: [],
            withoutLabels: [], labelsMatch: .all))
        #expect(preferences == Preferences())
        #expect(Preferences.checkIntervalOptions.contains(preferences.checkIntervalSeconds))
        #expect(Preferences.hideSuccessfulOptions.contains(preferences.hideSuccessfulAfter))
        #expect(Preferences.hideFailedOptions.contains(preferences.hideFailedAfter))
        #expect(Preferences.gitLabMaxAgeOptions.contains(preferences.gitLabMaxAgeSeconds))
        #expect(WorkItemFilters.limitOptions.contains(preferences.workItems.limit))
    }

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
                withLabels: ["uStatus::InProgress", "evil::$(touch pwned)"], withoutLabels: ["a|b"], labelsMatch: .any),
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
            key: .workItemsWithLabels, old: "", new: "uStatus::InProgress, evil::$(touch pwned)")))
        #expect(store.save(changed).isEmpty)
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

    @Test("only the values that changed are written and reported")
    func onlyChangedValues() {
        let suite = TemporaryDefaults()
        let store = PreferencesStore(defaults: suite.defaults)
        var preferences = store.load()
        preferences.alertStyle = .banner

        #expect(store.save(preferences) == [PreferencesStore.Change(key: .alertStyle, old: "window", new: "banner")])
        #expect(suite.defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("workItems") }.isEmpty)
        #expect(suite.defaults.string(forKey: "alertStyle") == "banner")
    }

    @Test("a value outside the options is saved as the default")
    func savesOptionsOnly() {
        let suite = TemporaryDefaults()
        let store = PreferencesStore(defaults: suite.defaults)

        #expect(store.save(Preferences(checkIntervalSeconds: 45, hideSuccessfulAfter: .hours(2))).isEmpty)
        #expect(store.load() == Preferences())
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
