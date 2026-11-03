import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("Card focus")
@MainActor
struct CardFocusRouterTests {
    @Test("INBOX-07 following an entry's link in the app asks for its card once; the browser asks for none")
    func followAsksForTheCard() throws {
        let router = WindowRouter { _ in }
        let page = try #require(URL(string: "https://gitlab.example.com/group/project/-/merge_requests/14"))
        var opened: [URL] = []
        var actions = GitLabSectionActions.none
        actions.open = { opened.append($0) }
        actions.focusCard = { router.requestCardFocus($0) }

        // Not an item of the app: the browser opens it, and nothing waits for a page that never shows.
        actions.openInApp = { _ in false }
        actions.follow(page, card: .claude)
        #expect(opened == [page])
        #expect(router.takeCardFocus() == nil)

        // An item of the app: it is shown, and its page takes the card once.
        actions.openInApp = { _ in true }
        actions.follow(page, card: .claude)
        #expect(opened == [page])
        #expect(router.cardFocus.pending?.card == .claude)
        #expect(router.takeCardFocus() == .claude)
        #expect(router.takeCardFocus() == nil)

        // An entry without a card shows the page from the top.
        actions.follow(page)
        #expect(router.takeCardFocus() == nil)
    }
}
