import MenubarCore
import Testing

@testable import MenubarUI

@Suite("Back and Forward menus")
struct NavigationEntriesTests {
    @Test(
        "WIN-08 a Back or Forward menu lists the places that still exist, the nearest first, at most its limit",
        arguments: [(limit: 50, expected: [3, 1, 0]), (limit: 2, expected: [3, 1])])
    func entries(limit: Int, expected: [Int]) {
        // The nearest first; place 2 is gone.
        let places = [3, 2, 1, 0].map { NavigationLocation(section: .mergeRequests, item: "mr-\($0)") }
        let entries = NavigationControls.entries(
            places, limit: limit, exists: { $0.item != "mr-2" }, title: { "Title \($0.item ?? "")" },
            systemImage: { $0.section.systemImage })
        #expect(entries.map(\.location.item) == expected.map { "mr-\($0)" })
        #expect(entries.map(\.id) == Array(0..<expected.count))
        #expect(entries.first?.title == "Title mr-3")
        #expect(entries.allSatisfy { $0.systemImage == "arrow.triangle.pull" })
    }
}
