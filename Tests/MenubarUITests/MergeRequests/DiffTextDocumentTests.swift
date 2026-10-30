import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

/// What a selection of characters in the diff's text means for Ask Claude (AI-07): the diff lines it touches.
@Suite("DiffTextSelection")
struct DiffTextDocumentTests {
    /// two hunks: context, a removed and two added lines, context; then a removed line and context
    private let hunks: [DiffHunk] = {
        let diff = """
            @@ -10,4 +10,5 @@ func run()
             let a = 1
            -let b = 2
            +let b = 3
            +let c = 4
             let d = 5
            @@ -40,2 +41,1 @@
            -let gone = 0
             let e = 6

            """
        guard case .hunks(let hunks) = UnifiedDiff.parse(diff) else {
            fatalError("the fixture diff has hunks")
        }
        return hunks
    }()

    private func document(_ layout: DiffLayoutChoice) -> DiffTextDocument {
        let styled = hunks.map { $0.lines.map { StyledLine(line: $0, segments: [.init(text: $0.text)]) } }
        return DiffTextDocument.make(hunks: hunks, styled: styled, layout: layout, limit: .max)
    }

    /// the characters from the offset into row `row` to the offset into row `end`
    private func range(_ document: DiffTextDocument, column: Int = 0, from row: Int, _ offset: Int = 0, to end: Int, _ endOffset: Int) -> NSRange {
        let starts = document.columns[column].starts
        return NSRange(location: starts[row] + offset, length: starts[end] + endOffset - (starts[row] + offset))
    }

    @Test("AI-07 a selection inside one line is that line, and a selected line with its newline is not the next one")
    func singleLine() throws {
        let document = document(.inline)
        // rows: 0 header, 1 `let a = 1`, 2 removed `let b = 2`, 3 added `let b = 3`, 4 added, 5 context, 6 header, 7 removed, 8 context
        let inside = try #require(document.pick(of: range(document, from: 3, 4, to: 3, 7), inColumn: 0, path: "A.swift"))
        #expect(inside.rows == 3...3)
        #expect(inside.selection == DiffSelection(path: "A.swift", anchor: .init(old: nil, new: 11), head: .init(old: nil, new: 11)))
        #expect(inside.selection.span(in: hunks) == LineSpan(first: 11, last: 11))
        // A triple-click: the whole line and its newline, which ends where the next row starts.
        let triple = try #require(document.pick(of: document.columns[0].range(ofRow: 1), inColumn: 0, path: "A.swift"))
        #expect(triple.rows == 1...1)
        #expect(document.pick(of: NSRange(location: 0, length: 0), inColumn: 0, path: "A.swift") == nil)
    }

    @Test("AI-07 a selection across a hunk boundary takes the lines of both hunks and skips the header between")
    func acrossHunks() throws {
        let document = document(.inline)
        let pick = try #require(document.pick(of: range(document, from: 4, 2, to: 8, 3), inColumn: 0, path: "A.swift"))
        #expect(pick.rows == 4...8)
        #expect(pick.selection.anchor == .init(old: nil, new: 12))
        #expect(pick.selection.head == .init(old: 41, new: 41))
        let lines = pick.selection.lines(in: hunks)
        #expect(lines.map(\.text) == ["let c = 4", "let d = 5", "let gone = 0", "let e = 6"])
        #expect(pick.selection.span(in: hunks) == LineSpan(first: 12, last: 41))
        // Only a header selected: no line to ask about.
        #expect(document.pick(of: document.columns[0].range(ofRow: 6), inColumn: 0, path: "A.swift") == nil)
    }

    @Test("AI-07 a selection of removed lines only asks about the old file's numbers")
    func removedOnly() throws {
        let document = document(.inline)
        let pick = try #require(document.pick(of: range(document, from: 7, to: 7, 5), inColumn: 0, path: "A.swift"))
        let span = try #require(pick.selection.span(in: hunks))
        #expect(span == LineSpan(first: 40, last: 40, isOld: true))
        #expect(span.buttonTitle == "Removed Line 40")
    }

    @Test("AI-07 side by side, each column selects its own file's lines and the padding rows are skipped")
    func sideBySide() throws {
        let document = document(.sideBySide)
        // rows: 0 header, 1 context, 2 removed|added `b`, 3 blank|added `c`, 4 context, 5 header, 6 removed|blank, 7 context
        #expect(document.columns.map(\.rows.count) == [8, 8])
        #expect(document.columns[0].rows[3].kind == .blank)
        let left = try #require(document.pick(of: range(document, column: 0, from: 2, to: 4, 3), inColumn: 0, path: "A.swift"))
        #expect(left.selection.lines(in: hunks).map(\.text).first == "let b = 2")
        #expect(left.selection.anchor == .init(old: 11, new: nil))
        #expect(left.selection.head == .init(old: 12, new: 13))
        let right = try #require(document.pick(of: range(document, column: 1, from: 2, to: 3, 4), inColumn: 1, path: "A.swift"))
        #expect(right.rows == 2...3)
        #expect(right.selection.span(in: hunks) == LineSpan(first: 11, last: 12))
        // Only the blank of the old side: nothing to ask about.
        #expect(document.pick(of: range(document, column: 0, from: 3, to: 3, 0), inColumn: 0, path: "A.swift") == nil)
        let removed = try #require(document.pick(of: document.columns[0].range(ofRow: 6), inColumn: 0, path: "A.swift"))
        #expect(removed.selection.span(in: hunks)?.isOld == true)
    }

    @Test("AI-07 a drag over the line numbers selects whole lines, from either end, across a hunk header")
    func gutterDrag() throws {
        let document = document(.inline)
        // from the added `let c = 4` (row 4) up to the first hunk's `let a = 1`... and down across the header (row 6) to row 8
        let down = document.characters(ofRows: 4, 8, inColumn: 0)
        let up = document.characters(ofRows: 8, 4, inColumn: 0)
        #expect(down == up)
        let pick = try #require(document.pick(of: down, inColumn: 0, path: "A.swift"))
        #expect(pick.rows == 4...8)
        #expect(pick.selection.lines(in: hunks).map(\.text) == ["let c = 4", "let d = 5", "let gone = 0", "let e = 6"])
        // One row, even an empty one: it keeps its newline, so the selection isn't empty.
        let single = document.characters(ofRows: 7, 7, inColumn: 0)
        #expect(document.pick(of: single, inColumn: 0, path: "A.swift")?.rows == 7...7)
        // Side by side, the old column's drag gives old lines.
        let sides = self.document(.sideBySide)
        let left = try #require(sides.pick(of: sides.characters(ofRows: 6, 7, inColumn: 0), inColumn: 0, path: "A.swift"))
        #expect(left.selection.span(in: hunks) == LineSpan(first: 41, last: 41))
        #expect(sides.code(in: sides.characters(ofRows: 1, 2, inColumn: 0), inColumn: 0) == "let a = 1\nlet b = 2")
    }

    @Test("AI-07 copying a selection gives the code without numbers, signs or hunk headers")
    func copiesCode() {
        let document = document(.inline)
        let copied = document.code(in: range(document, from: 3, 4, to: 8, 3), inColumn: 0)
        #expect(copied == "b = 3\nlet c = 4\nlet d = 5\nlet gone = 0\nlet")
    }

    @Test("AI-07 characters that end a paragraph in a text view don't split a row", arguments: [
        ("a\r", "a"), ("a\u{2028}b", "a b"), ("x\u{0C}", "x "), ("plain", "plain"),
    ])
    func sanitizes(text: String, expected: String) {
        #expect(DiffTextDocument.sanitized(text) == expected)
    }

    @Test("AI-07 the row at a position is found by the rows' tops")
    func rowAtPosition() {
        let tops: [CGFloat] = [0, 19, 34, 49, 64]
        #expect(DiffTextDocument.row(at: -5, tops: tops) == 0)
        #expect(DiffTextDocument.row(at: 18.9, tops: tops) == 0)
        #expect(DiffTextDocument.row(at: 19, tops: tops) == 1)
        #expect(DiffTextDocument.row(at: 63, tops: tops) == 3)
        #expect(DiffTextDocument.row(at: 900, tops: tops) == 3)
        #expect(DiffTextDocument.row(at: 5, tops: [0]) == nil)
    }
}
