import AppKit
import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("SyntaxStyle")
@MainActor
struct SyntaxStyleTests {
    @Test("LOG-02 the colored text is the raw text, with the spans colored and the rest plain")
    func attributedStringKeepsTheText() throws {
        let record = RequestRecord(
            method: "GET", url: URL(string: "https://jenkins.example.com/api/json")!, status: 200, seconds: 1,
            responseBody: Data(#"{"result":"SUCCESS","n":1}"#.utf8))
        let styled = try #require(record.styledBody)
        let attributed = SyntaxStyle.attributedString(styled)

        #expect(attributed.string == styled.text)
        let colors = styled.spans.map { span in
            attributed.attribute(.foregroundColor, at: span.range.lowerBound, effectiveRange: nil) as? NSColor
        }
        #expect(colors.allSatisfy { $0 != nil })
        // keys, strings and results differ from each other; the whitespace between the tokens keeps the label color
        #expect(colors[1] != colors[3])
        #expect(attributed.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor == NSColor.textColor)
    }
}
