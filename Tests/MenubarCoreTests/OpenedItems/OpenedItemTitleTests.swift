import Testing

@testable import MenubarCore

/// The title of an opened item's sidebar row (WIN-06).
@Suite("OpenedItemTitle")
struct OpenedItemTitleTests {
    @Test(
        "WIN-06 a leading work item number leaves the row's title and goes to its chip, a number elsewhere stays",
        arguments: [
            ("#123 Add the target", "Add the target", 123 as Int?),
            ("#123: Add the target", "Add the target", 123),
            ("#123 - Add the target", "Add the target", 123),
            ("  #15327   Add the target", "Add the target", 15327),
            ("Draft: #123 Add the target", "Draft: Add the target", 123),
            ("[Draft] #123: Add the target", "[Draft] Add the target", 123),
            ("Add the target", "Add the target", nil),
            ("Fix #123 in the dialog", "Fix #123 in the dialog", nil),
            ("#123abc is not a number", "#123abc is not a number", nil),
            ("#123", "#123", nil),
            ("", "", nil),
        ])
    func split(title: String, shown: String, number: Int?) {
        let result = OpenedItemTitle.split(title)
        #expect(result.title == shown)
        #expect(result.workItemNumber == number)
    }
}
