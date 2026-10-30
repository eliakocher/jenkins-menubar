import Foundation
import Testing

@testable import MenubarCore

/// The syntax colors, the changed parts and the side-by-side rows of a diff (MR-11).
@Suite("Diff styling")
struct DiffStylingTests {
    private static func line(_ kind: DiffLine.Kind, _ text: String) -> DiffLine {
        DiffLine(kind: kind, text: text, oldNumber: kind == .added ? nil : 1, newNumber: kind == .removed ? nil : 1)
    }

    private static func hunk(_ lines: [DiffLine]) -> DiffHunk {
        DiffHunk(oldStart: 1, oldCount: lines.count, newStart: 1, newCount: lines.count, lines: lines)
    }

    /// The colored pieces of a styled line, as `kind:text`.
    private static func tokens(_ line: StyledLine) -> [String] {
        line.segments.compactMap { segment in segment.token.map { "\($0):\(segment.text)" } }
    }

    @Test(
        "MR-11 colors keywords, strings, comments, numbers, types and annotations by the file's language",
        arguments: [
            (
                "Sources/App.swift", #"@MainActor let name: String = "app" // the name"#,
                ["attribute:@MainActor", "keyword:let", "type:String", #"string:"app""#, "comment:// the name"]
            ),
            ("Jenkinsfile", "def retries = 3", ["keyword:def", "number:3"]),
            ("web/app.ts", "export const limit = `${max}`", ["keyword:export", "keyword:const", "string:`${max}`"]),
            ("ci/.gitlab-ci.yml", "  stage: test # later", ["attribute:stage", "comment:# later"]),
            ("run.sh", #"echo "$HOME" # x"#, ["keyword:echo", #"string:"$HOME""#, "comment:# x"]),
            ("pom.xml", #"<version id="2">"#, ["keyword:<version", "attribute:id", #"string:"2""#]),
            ("notes.txt", "let it be", []),
        ])
    func colors(_ path: String, text: String, expected: [String]) {
        let styled = DiffStyling.style([Self.hunk([Self.line(.context, text)])], path: path)
        #expect(Self.tokens(styled[0][0]) == expected)
        // The pieces put back together are the line.
        #expect(styled[0][0].segments.map(\.text).joined() == text)
    }

    @Test("MR-11 a block comment goes on in the next lines of its own side")
    func blockComments() {
        let styled = DiffStyling.style(
            [
                Self.hunk([
                    Self.line(.removed, "/* old"), Self.line(.added, "let a = 1"), Self.line(.removed, "still old */ let b"),
                    Self.line(.context, "let c"),
                ])
            ], path: "A.swift")[0]
        #expect(Self.tokens(styled[0]) == ["comment:/* old"])
        // The added line isn't inside the removed side's comment.
        #expect(Self.tokens(styled[1]) == ["keyword:let", "number:1"])
        #expect(Self.tokens(styled[2]) == ["comment:still old */", "keyword:let"])
        #expect(Self.tokens(styled[3]) == ["keyword:let"])
    }

    @Test("MR-11 a changed line marks only the part that differs from its partner")
    func changedParts() {
        let lines = [
            Self.line(.removed, "timeout = 30 seconds"), Self.line(.removed, "abc"), Self.line(.added, "timeout = 20 seconds"),
            Self.line(.added, "xyz"), Self.line(.added, "extra"),
        ]
        let ranges = DiffStyling.changedRanges(lines)
        #expect(ranges[0] == 10..<11 && ranges[2] == 10..<11)
        // Nothing in common: the whole line changed, no part is marked; an added line without a partner neither.
        #expect(ranges[1] == nil && ranges[3] == nil && ranges[4] == nil)
        let styled = DiffStyling.style([Self.hunk(lines)], path: "notes.txt")[0]
        #expect(styled[2].segments.filter(\.isChanged).map(\.text) == ["2"])
    }

    @Test("MR-11 side by side puts removed next to added lines, context on both sides")
    func sideBySide() {
        let styled = DiffStyling.style(
            [
                Self.hunk([
                    Self.line(.context, "a"), Self.line(.removed, "b"), Self.line(.removed, "c"), Self.line(.added, "B"),
                    Self.line(.context, "d"), Self.line(.added, "e"),
                ])
            ], path: "x.txt")[0]
        let rows = DiffStyling.split(styled).map { ($0.left?.line.text ?? "-") + "|" + ($0.right?.line.text ?? "-") }
        #expect(rows == ["a|a", "b|B", "c|-", "d|d", "-|e"])
    }
}
