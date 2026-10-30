import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("Main window")
@MainActor
struct MainWindowTests {
    @Test(
        "WIN-02 showing a section marks it visible",
        arguments: [
            (MainWindowSection.pipelines, Set<Surface>()),
            (.mergeRequests, [.mergeRequests]),
            (.workItems, [.workItems]),
            (.activity, []),
        ] as [(MainWindowSection, Set<Surface>)])
    func showingMarksVisible(section: MainWindowSection, surfaces: Set<Surface>) {
        // Covered or minimized, the window still shows its selected section.
        #expect(MainWindowSurfaces.shown(section: section, isOnScreen: false) == surfaces)

        let router = WindowRouter { _ in }
        #expect(router.surfaces(surfaces, shownBy: MainWindowSurfaces.host) == surfaces)
        // Closing the window leaves what the panel shows.
        _ = router.surfaces(PanelView.surfaces, shownBy: PanelView.host)
        #expect(router.surfaces([], shownBy: MainWindowSurfaces.host) == PanelView.surfaces)
    }

    @Test(
        "WIN-04 reload loads only the shown section, and the selected row's detail only with a selection",
        arguments: [
            (MainWindowSection.pipelines, false, [MainWindowReload.Step.builds]),
            (.mergeRequests, false, [.mergeRequestList]),
            (.mergeRequests, true, [.mergeRequestList, .mergeRequestDetails]),
            (.workItems, false, [.workItemList]),
            (.workItems, true, [.workItemList, .workItemDetails]),
            (.slots, true, [.slots]),
            (.workspaces, true, [.workspaces]),
            (.activity, true, []),
        ] as [(MainWindowSection, Bool, [MainWindowReload.Step])])
    func reloadsTheShownSection(section: MainWindowSection, selected: Bool, steps: [MainWindowReload.Step]) {
        let selection = selected
            ? MainWindowSelection(
                pipelines: "job", mergeRequests: URL(string: "https://gitlab.example/mr/1"), workItems: "item")
            : MainWindowSelection()
        #expect(MainWindowReload.steps(for: section, selection: selection) == steps)
    }

    @Test("OD-02 sidebar badges keep MRs and work items loading while the window is on screen", arguments: MainWindowSection.allCases)
    func badgesKeepLoading(section: MainWindowSection) {
        #expect(MainWindowSurfaces.shown(section: section, isOnScreen: true) == [.mergeRequests, .workItems])
    }

    @Test("WIN-05 restores the section and the selection")
    func restoresSectionAndSelection() throws {
        let suite = "menubar-monitor-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mergeRequest = try #require(URL(string: "https://gitlab.example.com/group/project/-/merge_requests/14"))

        let first = WindowRouter(defaults: defaults) { _ in }
        #expect(first.section == .pipelines)
        first.selection.pipelines = "MR-12"
        first.showInMergeRequests(mergeRequest)
        first.selection.workItems = "group/project#31"
        first.selection.activity = ["1-0"]

        let second = WindowRouter(defaults: defaults) { _ in }
        #expect(second.section == .mergeRequests)
        #expect(second.selection == MainWindowSelection(
            pipelines: "MR-12", mergeRequests: mergeRequest, workItems: "group/project#31", activity: ["1-0"]))

        // Activity's is kept only while one entry is selected; a cleared selection is gone after a restart too.
        second.selection.activity = ["1-0", "2-0"]
        second.selection.pipelines = nil
        second.open(.activity)
        let third = WindowRouter(defaults: defaults) { _ in }
        #expect(third.section == .activity)
        #expect(third.selection.activity.isEmpty)
        #expect(third.selection.pipelines == nil)
        #expect(third.selection.workItems == "group/project#31")
    }
}
