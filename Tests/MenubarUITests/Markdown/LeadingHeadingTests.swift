import Foundation
import Testing

@testable import MenubarUI

@Suite("LeadingHeading")
struct LeadingHeadingTests {
    @Test(
        "WIN-02 drops a first heading that repeats the card's title, and only that",
        arguments: [
            ("## Description\n\nThe text.", 1),
            ("# description  \n\nThe text.", 1),
            ("## Problem\n\nThe text.", 2),
            ("The text.\n\n## Description\n\nMore.", 3),
            ("## Description", 0),
        ])
    func dropsRepeatedTitle(markdown: String, blocks: Int) {
        let document = MarkdownDocument(parsing: markdown, base: nil).droppingLeadingHeading(titled: "Description")

        #expect(document.blocks.count == blocks)
    }
}
