import MenubarCore
import Testing

@testable import MenubarUI

@Suite("MainWindowSearch")
struct MainWindowSearchTests {
    @Test(
        "WIN-06 over an opened item the search belongs to its kind: its section and its placeholder",
        arguments: [
            (OpenedItem.Kind.build, MainWindowSection.pipelines, "Search builds"),
            (.mergeRequest, .mergeRequests, "Search merge requests"),
            (.workItem, .workItems, "Search work items"),
        ] as [(OpenedItem.Kind, MainWindowSection, String)])
    func scope(kind: OpenedItem.Kind, section: MainWindowSection, prompt: String) {
        #expect(MainWindowSearch.section(for: kind) == section)
        #expect(MainWindowSearch.isOffered(section: .activity, opened: kind))
        // Whatever section the window came from, the placeholder names the kind.
        #expect(MainWindowSearch.prompt(section: .activity, opened: kind) == prompt)
    }

    @Test("WIN-06 without an opened item the field is the section's own", arguments: MainWindowSection.allCases)
    func ownField(section: MainWindowSection) {
        #expect(MainWindowSearch.prompt(section: section, opened: nil) == section.searchPrompt)
        #expect(MainWindowSearch.isOffered(section: section, opened: nil) == section.isSearchable)
    }

    @Test(
        "WIN-06 typing over an opened item takes the window to its kind's section; clearing, or any text over a list, does not",
        arguments: [
            ("login", OpenedItem.Kind.build, MainWindowSection.pipelines),
            ("login", .mergeRequest, .mergeRequests),
            ("login", .workItem, .workItems),
            ("", .build, nil),
            ("", .mergeRequest, nil),
            ("login", nil, nil),
            ("", nil, nil),
        ] as [(String, OpenedItem.Kind?, MainWindowSection?)])
    func destination(typed: String, kind: OpenedItem.Kind?, expected: MainWindowSection?) {
        #expect(MainWindowSearch.destination(typed: typed, opened: kind) == expected)
    }
}
