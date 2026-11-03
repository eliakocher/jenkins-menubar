import Foundation
import Testing

@testable import MenubarCore

/// The position of a comment on selected lines of a merge request's diff (CMT-03).
@Suite("Diff positions")
struct DiffPositionTests {
    private static let refs = DiffRefs(baseSha: "base", headSha: "head", startSha: "start")

    /// `-10,6 +10,7`: a, b, -c, +d, +e, f, g, h; old lines 10 11 12 · 13 14 15, new lines 10 11 · 12 13 14 15 16
    private static let diff = """
        @@ -10,6 +10,7 @@ func run()
         a
         b
        -c
        +d
        +e
         f
         g
         h
        """

    private static func file(oldPath: String = "src/App.swift", newPath: String = "src/App.swift", kind: MergeRequestChanges.FileChange.Kind = .modified)
        -> MergeRequestChanges.FileChange
    {
        .init(oldPath: oldPath, newPath: newPath, kind: kind, content: UnifiedDiff.parse(diff))
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var index: Int
        var oldLine: Int?
        var newLine: Int?
        var testDescription: String { name }
    }

    @Test(
        "CMT-03 one line: an added line has only its new number, a removed line only its old one, an unchanged line both",
        arguments: [
            Case(name: "added d", index: 3, oldLine: nil, newLine: 12),
            Case(name: "removed c", index: 2, oldLine: 12, newLine: nil),
            Case(name: "unchanged f", index: 5, oldLine: 13, newLine: 14),
        ])
    func oneLine(_ example: Case) throws {
        let position = try DiffPositionBuilder.position(
            in: Self.file(), selection: DiffLineSelection(hunk: 0, first: example.index), refs: Self.refs)

        #expect(position.oldLine == example.oldLine && position.newLine == example.newLine)
        #expect(position.oldPath == "src/App.swift" && position.newPath == "src/App.swift")
        #expect(position.refs == Self.refs && position.range == nil)
    }

    @Test("CMT-03 a renamed file keeps its old and its new path")
    func renamed() throws {
        let file = Self.file(oldPath: "src/Old.swift", newPath: "lib/New.swift", kind: .renamed)

        let position = try DiffPositionBuilder.position(in: file, selection: DiffLineSelection(hunk: 0, first: 5), refs: Self.refs)

        #expect(position.oldPath == "src/Old.swift" && position.newPath == "lib/New.swift")
        #expect(position.oldLine == 13 && position.newLine == 14)
    }

    @Test("CMT-03 several lines sit on the last one, with the first in the range and GitLab's line codes; either order of the ends")
    func range() throws {
        // b (unchanged) to e (added); the code is sha1 of the path, then the old and the new counter of the line.
        let sha = "4fc708880923014fc1e0b714a6b5e789083d0b56"
        for (first, last) in [(1, 4), (4, 1)] {
            let position = try DiffPositionBuilder.position(
                in: Self.file(), selection: DiffLineSelection(hunk: 0, first: first, last: last), refs: Self.refs)

            #expect(position.oldLine == nil && position.newLine == 13)
            let range = try #require(position.range)
            #expect(range.start == .init(lineCode: "\(sha)_11_11", side: nil, oldLine: 11, newLine: 11))
            #expect(range.end == .init(lineCode: "\(sha)_13_13", side: .new, oldLine: nil, newLine: 13))
        }
    }

    @Test("CMT-03 a range ending on a removed line is placed by its old line, and a deleted file is named by its old path")
    func removedRangeAndDeleted() throws {
        let position = try DiffPositionBuilder.position(in: Self.file(), selection: DiffLineSelection(hunk: 0, first: 0, last: 2), refs: Self.refs)
        #expect(position.oldLine == 12 && position.newLine == nil)
        #expect(position.range?.end.side == .old && position.range?.end.lineCode.hasSuffix("_12_12") == true)

        let deleted = MergeRequestChanges.FileChange(
            oldPath: "src/Gone.swift", newPath: "src/Gone.swift", kind: .deleted, content: UnifiedDiff.parse("@@ -1,2 +0,0 @@\n-x\n-y"))
        let gone = try DiffPositionBuilder.position(in: deleted, selection: DiffLineSelection(hunk: 0, first: 0, last: 1), refs: Self.refs)
        #expect(gone.oldLine == 2 && gone.newLine == nil && gone.oldPath == "src/Gone.swift")
    }

    @Test("CMT-03 a file without a shown diff, or a selection outside it, has no position")
    func refusals() {
        let notShown = MergeRequestChanges.FileChange(oldPath: "a", newPath: "a", kind: .modified, content: .notLoaded)
        #expect(throws: DiffPositionError.noDiff) {
            try DiffPositionBuilder.position(in: notShown, selection: DiffLineSelection(hunk: 0, first: 0), refs: Self.refs)
        }
        #expect(throws: DiffPositionError.outOfRange) {
            try DiffPositionBuilder.position(in: Self.file(), selection: DiffLineSelection(hunk: 1, first: 0), refs: Self.refs)
        }
        #expect(throws: DiffPositionError.outOfRange) {
            try DiffPositionBuilder.position(in: Self.file(), selection: DiffLineSelection(hunk: 0, first: 2, last: 99), refs: Self.refs)
        }
    }
}
