import Foundation
import Testing

@testable import MenubarUI

/// The safety rules of the rendered descriptions (WIN-02).
@Suite("MarkdownDocument")
struct MarkdownDocumentTests {
    private static let issue = URL(string: "https://gitlab.example.com/group/project/-/issues/31")!
    private static let epic = URL(string: "https://gitlab.example.com/groups/group/-/epics/7")!

    /// A description and the blocks it shows.
    struct Case: Sendable, CustomTestStringConvertible {
        var markdown: String
        var base = MarkdownDocumentTests.issue
        var blocks: [MarkdownBlock]
        var testDescription: String { markdown }
    }

    static let cases: [Case] = [
        Case(markdown: "[docs](https://example.com/docs)", blocks: [.paragraph(link("docs", "https://example.com/docs"))]),
        Case(markdown: "[run](javascript:alert(1))", blocks: [.paragraph("run")]),
        Case(markdown: "[app](menubar-monitor://settings/accounts)", blocks: [.paragraph("app")]),
        Case(markdown: "[file](file:///etc/hosts)", blocks: [.paragraph("file")]),
        Case(markdown: "[mail](mailto:alex@example.com)", blocks: [.paragraph("mail")]),
        Case(markdown: "[issue](/group/project/-/issues/5)",
             blocks: [.paragraph(link("issue", "https://gitlab.example.com/group/project/-/issues/5"))]),
        Case(markdown: "![shot](/uploads/abc/shot.png)",
             blocks: [.paragraph(link("Image: shot", "https://gitlab.example.com/group/project/uploads/abc/shot.png"))]),
        Case(markdown: "![image](/uploads/abc/shot.png)", base: epic,
             blocks: [.paragraph(link("Image: shot.png", "https://gitlab.example.com/groups/group/-/uploads/abc/shot.png"))]),
        Case(markdown: "![x](javascript:alert(1))", blocks: [.paragraph("Image: x")]),
        Case(markdown: "see https://example.com/x now",
             blocks: [.paragraph("see " + link("https://example.com/x", "https://example.com/x") + " now")]),
        Case(markdown: #"<a href="https://example.com">x</a> and <script>alert(1)</script>"#,
             blocks: [.paragraph(#"<a href="https://example.com">x</a> and <script>alert(1)</script>"#)]),
        Case(markdown: "<details><summary>More</summary>hidden</details>",
             blocks: [.rawText("<details><summary>More</summary>hidden</details>")]),
        Case(markdown: "<!-- Describe the change. -->\n\nText<!-- hint --> here", blocks: [.paragraph("Text here")]),
    ]

    @Test("WIN-02 descriptions link only web addresses, never load images and show HTML as text", arguments: cases)
    func safety(_ item: Case) {
        #expect(MarkdownDocument(parsing: item.markdown, base: item.base).blocks == item.blocks)
    }

    private static func link(_ text: String, _ url: String) -> AttributedString {
        var linked = AttributedString(text)
        linked.link = URL(string: url)
        return linked
    }
}
