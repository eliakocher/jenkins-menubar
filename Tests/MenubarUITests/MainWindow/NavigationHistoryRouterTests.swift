import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("Main window history")
@MainActor
struct NavigationHistoryRouterTests {
    @Test("WIN-08 every way of navigating is noted once; Back and Forward restore without noting")
    func recordsAndRestores() throws {
        let suite = "menubar-monitor-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory
            .appending(path: "menubar-monitor-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let model = AppModel(dependencies: .fake(root: root, defaults: defaults))
        let router = WindowRouter(defaults: defaults) { _ in }
        let mergeRequest = try #require(URL(string: "https://gitlab.example.com/group/project/-/merge_requests/14"))
        #expect(!router.history.canGoBack)

        // The sidebar, then a row, then a "Show in …" button of a detail that switches the section and selects a row.
        router.section = .workItems
        router.selection.workItems = "group/project#31"
        router.showInMergeRequests(mergeRequest)
        router.section = .mergeRequests
        #expect(router.history.backEntries.map(\.section) == [.workItems, .workItems, .pipelines])
        #expect(router.history.backEntries.map(\.item) == ["group/project#31", nil, nil])

        // A selection that is cleared (Hide, Stop Watching) is no navigation, and neither is a selection in a hidden section.
        router.selection.mergeRequests = nil
        router.selection.workItems = "group/project#99"
        #expect(router.history.backStack.count == 3)

        router.goBack(model: model)
        #expect(router.section == .workItems)
        #expect(router.selection.workItems == "group/project#31")
        #expect(router.history.canGoForward)
        #expect(router.history.backStack.count == 2)
        router.goForward(model: model)
        #expect(router.section == .mergeRequests)
        #expect(!router.history.canGoForward)

        // Navigating after Back drops what was ahead.
        router.goBack(model: model)
        router.section = .activity
        #expect(!router.history.canGoForward)
        #expect(router.history.current == NavigationLocation(section: .activity))
    }
}
