import Foundation
import SwiftUI
import Testing

@testable import MenubarUI

/// The safety rules of the rendered descriptions, GitLab's references, callouts and code colors (WIN-02).
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

    /// A text and the links its references and mentions get: `nil` for text that stays plain.
    struct Reference: Sendable, CustomTestStringConvertible {
        var markdown: String
        var base: URL? = MarkdownDocumentTests.mergeRequest
        var links: [String: String?]
        var testDescription: String { markdown }
    }

    private static let mergeRequest = URL(string: "https://gitlab.example.com/group/project/-/merge_requests/14")!

    static let references: [Reference] = [
        Reference(markdown: "Closes #31 and !12.", links: [
            "#31": "https://gitlab.example.com/group/project/-/issues/31",
            "!12": "https://gitlab.example.com/group/project/-/merge_requests/12",
        ]),
        Reference(markdown: "see group/other!7 (and @slee)", links: [
            "group/other!7": "https://gitlab.example.com/group/other/-/merge_requests/7",
            "@slee": "https://gitlab.example.com/slee",
        ]),
        Reference(markdown: "mail alex@example.com, issue#3, wow!12, a/b#4x, `!12`", links: [:]),
        Reference(markdown: "cc @all", links: ["@all": nil]),
        // A Jenkins page tells no project: references stay text, a mention is marked without a link.
        Reference(markdown: "#31 by @slee", base: URL(string: "https://jenkins.example.com/job/project/412/"), links: ["@slee": nil]),
        Reference(markdown: "!12 by @slee", base: nil, links: ["@slee": nil]),
        Reference(markdown: "#31 in a group", base: MarkdownDocumentTests.epic, links: [:]),
    ]

    @Test("WIN-02 references and mentions link to the item and the user on the page's GitLab, never inside words or code", arguments: references)
    func gitLabReferences(_ item: Reference) throws {
        let document = MarkdownDocument(parsing: item.markdown, base: item.base)
        guard case .paragraph(let text)? = document.blocks.first else {
            Issue.record("no paragraph")
            return
        }
        var found: [String: String?] = [:]
        for run in text.runs where run[MarkdownRoleAttribute.self] != nil {
            found.updateValue(run.link?.absoluteString, forKey: String(text[run.range].characters))
        }
        #expect(found == item.links)
    }

    @Test("WIN-02 a quote that starts with [!NOTE], [!TIP], [!IMPORTANT], [!WARNING] or [!CAUTION] is a callout", arguments: [
        ("> [!WARNING]\n> Keep the old names.", MarkdownBlock.callout(.warning, [.paragraph("Keep the old names.")])),
        ("> [!note] Short.", .callout(.note, [.paragraph("Short.")])),
        ("> [!TIP]", .callout(.tip, [])),
        ("> [!LATER] Not a kind.", .quote([.paragraph("[!LATER] Not a kind.")])),
    ])
    func callouts(_ markdown: String, _ block: MarkdownBlock) {
        #expect(MarkdownDocument(parsing: markdown, base: nil).blocks == [block])
    }

    @Test("WIN-02 code blocks color their language's keywords, strings, comments and numbers, and stay plain without one", arguments: [
        ("swift", "let x = \"a\" // b 42", [("let", MarkdownSyntax.Kind.keyword), ("\"a\"", .string), ("// b 42", .comment)]),
        ("python", "def f(): return 42  # done", [("def", .keyword), ("return", .keyword), ("42", .number), ("# done", .comment)]),
        ("json", "{\"key\": true, \"n\": 1.5}", [("\"key\"", .attribute), ("true", .keyword), ("\"n\"", .attribute), ("1.5", .number)]),
        ("bash", "echo \"$HOME\" # x", [("echo", .keyword), ("\"$HOME\"", .string), ("# x", .comment)]),
        ("diff", "-old\n+new\n same", [("-old", .removed), ("+new", .added)]),
        ("unknown-language", "let x = 1", []),
    ] as [(String, String, [(String, MarkdownSyntax.Kind)])])
    func syntax(_ language: String, _ code: String, _ expected: [(String, MarkdownSyntax.Kind)]) {
        let highlighted = MarkdownSyntax.highlight(code, language: language)
        #expect(String(highlighted.characters) == code)
        var colored: [String] = []
        for run in highlighted.runs where run.swiftUI.foregroundColor != nil {
            colored.append(String(highlighted[run.range].characters))
        }
        #expect(colored == expected.map(\.0))
        for (piece, kind) in expected {
            let range = highlighted.range(of: piece)
            #expect(range.flatMap { highlighted[$0].runs.first?.swiftUI.foregroundColor } == MarkdownSyntax.color(kind))
        }
    }

    private static func link(_ text: String, _ url: String) -> AttributedString {
        var linked = AttributedString(text)
        linked.link = URL(string: url)
        return linked
    }
}
