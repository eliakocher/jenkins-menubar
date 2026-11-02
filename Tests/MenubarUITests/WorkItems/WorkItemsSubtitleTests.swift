import Testing

@testable import MenubarUI

@Suite("MainWindowSearch")
struct MainWindowSearchTests {
    @Test(
        "WIN-06 typing over an opened item returns to the section's list; clearing, or any text over a list, does not",
        arguments: [("login", true, true), ("", true, false), ("login", false, false), ("", false, false)] as [(String, Bool, Bool)])
    func returnsToList(typed: String, isOpenedItemShown: Bool, expected: Bool) {
        #expect(MainWindowSearch.returnsToList(typed: typed, isOpenedItemShown: isOpenedItemShown) == expected)
    }
}
