import Foundation
import Testing

@testable import MenubarCore

/// What the menu bar shows, from Settings → Menu Bar (APP-11).
@Suite("Menu bar layout")
struct MenuBarLayoutTests {
    private typealias Part = MenuBarLayout.ItemPart

    @Test("APP-11 preferences from before the layout read as the old look")
    func oldPreferencesReadAsDefault() throws {
        let layout = MenuBarLayout()
        #expect(layout.shownParts == [.problem, .running, .failed, .unstable, .successful, .inbox])
        #expect(layout.butler == .whenIdle && layout.inboxStyle == .dot && layout.hidesZeroCounts)
        #expect(layout.shownRows.map(\.section) == [.pipelines, .inbox, .mergeRequests, .workItems])
        #expect(layout.rows.allSatisfy { $0.showsFlyout && $0.flyoutRows == 20 })
        #expect(layout.paneWidth == .regular && layout.isDefaultItem && layout.isDefaultPane)

        // Preferences encoded before the field existed, and a suite without the key.
        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"checkIntervalSeconds": 120}"#.utf8))
        #expect(old.menuBarLayout == layout)
        let suite = TemporaryDefaults()
        let store = PreferencesStore(defaults: suite.defaults)
        #expect(store.load().menuBarLayout == layout)
        // Text that isn't a layout, and a layout with values of the wrong type, read as the default.
        suite.defaults.set("{not json", forKey: PreferencesStore.menuBarLayoutKey)
        #expect(store.load().menuBarLayout == layout)
        suite.defaults.set(#"{"butler": 3, "parts": "running", "paneWidth": "huge", "rows": [{"section": 1}]}"#, forKey: PreferencesStore.menuBarLayoutKey)
        #expect(store.load().menuBarLayout == layout)
    }

    @Test("APP-11 a saved layout keeps its order; unknown ids go, new ones take their default place")
    func mergesSavedLayout() throws {
        // Saved by a version that had only some parts, plus one that is gone and a repeat.
        let text = #"""
            {"butler": "always", "inboxStyle": "count", "hidesZeroCounts": false, "paneWidth": "compact",
             "parts": [{"part": "failed", "isOn": true}, {"part": "gone", "isOn": true}, {"part": "running", "isOn": false},
                       {"part": "failed", "isOn": false}, {"part": "inbox"}],
             "rows": [{"section": "work-items", "isOn": true, "showsFlyout": false, "flyoutRows": 5},
                      {"section": "digest", "isOn": true}, {"section": "pipelines", "isOn": false, "flyoutRows": 7}]}
            """#
        let layout = try JSONDecoder().decode(MenuBarLayout.self, from: Data(text.utf8))
        #expect(layout.butler == .always && layout.inboxStyle == .count && !layout.hidesZeroCounts)
        #expect(layout.paneWidth == .compact)
        // Saved order first, a new part right after its default predecessor: the problem marker has none, so it
        // starts; unstable follows failed. A switch it didn't save is the part's default.
        #expect(layout.parts.map(\.part) == [.problem, .failed, .unstable, .successful, .running, .inbox, .reviews, .slot])
        #expect(layout.shownParts == [.problem, .failed, .unstable, .successful, .inbox])
        // A section without a pane row is dropped; the Inbox and Merge Requests come back after Pipelines.
        #expect(layout.rows.map(\.section) == [.workItems, .pipelines, .inbox, .mergeRequests])
        #expect(layout.row(.workItems) == MenuBarLayout.Row(.workItems, showsFlyout: false, flyoutRows: 5))
        // A number of entries outside the options reads as the default.
        #expect(layout.row(.pipelines) == MenuBarLayout.Row(.pipelines, isOn: false, flyoutRows: 20))
        #expect(layout.shownRows.map(\.section) == [.workItems, .inbox, .mergeRequests])
        #expect(!layout.isDefaultItem && !layout.isDefaultPane)

        // The resets are per group.
        var reset = layout
        reset.resetItem()
        #expect(reset.isDefaultItem && reset.rows == layout.rows)
        reset.resetPane()
        #expect(reset == MenuBarLayout())
    }

    @Test("APP-11 the layout is saved as one key, survives a backup, and the default leaves no key")
    func savedAndBackedUp() throws {
        #expect(PersonalSettingsBackup.allowlist.contains(PersonalSettingsBackup.Entry(PreferencesStore.menuBarLayoutKey, .string)))
        var layout = MenuBarLayout()
        layout.setPart(.reviews, isOn: true)
        layout.moveParts(from: [7], to: 0)
        layout.moveRows(from: [3], to: 0)
        layout.updateRow(.inbox) { $0.flyoutRows = 13 }
        #expect(layout.parts.first == MenuBarLayout.Part(.slot, isOn: false))
        #expect(layout.row(.inbox).flyoutRows == 20)

        let source = TemporaryDefaults()
        let store = PreferencesStore(defaults: source.defaults)
        store.save(Preferences(menuBarLayout: layout))
        #expect(store.load().menuBarLayout == layout)
        let data = try PersonalSettingsBackup.export(from: source.defaults)
        let target = TemporaryDefaults()
        _ = try PersonalSettingsBackup.importValues(from: data, into: target.defaults)
        #expect(PreferencesStore(defaults: target.defaults).load().menuBarLayout == layout)

        store.save(Preferences())
        #expect(source.defaults.object(forKey: PreferencesStore.menuBarLayoutKey) == nil)
    }
}
