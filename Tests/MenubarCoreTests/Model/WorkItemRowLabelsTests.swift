import Foundation
import Testing

@testable import MenubarCore

@Suite("WorkItemRowLabels")
struct WorkItemRowLabelsTests {
    @Test(
        "WI-04 a row's label: hidden by prefix of its title, ignoring case, or shown by its value only",
        arguments: [
            // hidden, value only, title, what the row shows
            (["group:"], false, "group:SquadA", nil),
            (["group:"], false, "group::SquadA", nil),
            (["Affects::"], false, "affects::1.0", nil),
            (["affects::"], false, "affects:1.0", "affects:1.0"),
            (["  group: ", ""], false, "triage::Maintainer", "triage::Maintainer"),
            // an empty entry hides nothing
            ([""], false, "bug", "bug"),
            ([], true, "priority::high", "high"),
            ([], true, "a::b::c", "c"),
            // not scoped, or no value: the title stays
            ([], true, "group:SquadA", "group:SquadA"),
            ([], true, "dangling::", "dangling::"),
            // hiding goes first
            (["priority"], true, "priority::high", nil),
            ([], false, "priority::high", "priority::high"),
        ] as [([String], Bool, String, String?)])
    func labelText(hidden: [String], valueOnly: Bool, title: String, shown: String?) {
        #expect(WorkItemRowLabels(hidden: hidden, showsScopedValueOnly: valueOnly).text(of: title) == shown)
    }

    @Test("WI-04 typed entries are trimmed, without empty ones and repeats")
    func entries() {
        #expect(WorkItemRowLabels.entries(from: " group: , affects::,, GROUP:,") == ["group:", "affects::"])
        #expect(WorkItemRowLabels.entries(from: "  ").isEmpty)
    }

    @Test("WI-04 the preference is saved, read back, and decodes from before it existed")
    func preference() throws {
        let suite = TemporaryDefaults()
        let store = PreferencesStore(defaults: suite.defaults)
        var preferences = Preferences()
        preferences.workItemRows = WorkItemRowLabels(hidden: ["group:", "affects::"], showsScopedValueOnly: true)
        let changes = store.save(preferences)
        #expect(Set(changes.map(\.key)) == [.workItemsHideOnRows, .workItemsScopedValueOnly])
        #expect(store.load().workItemRows == preferences.workItemRows)
        // Display only: it isn't part of the filters, whose change reloads the work items.
        #expect(store.load().workItems == WorkItemFilters())
        // And a backup carries both keys.
        let keys = PersonalSettingsBackup.allowlist.map(\.key)
        #expect(keys.contains("workItemsHideOnRows") && keys.contains("workItemsScopedValueOnly"))

        let old = Data(#"{"checkIntervalSeconds": 60}"#.utf8)
        #expect(try JSONDecoder().decode(Preferences.self, from: old).workItemRows.isDefault)
    }
}
