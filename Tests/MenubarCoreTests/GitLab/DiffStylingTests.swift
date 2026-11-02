import Foundation
import Testing

@testable import MenubarCore

/// The side-by-side rows of a diff (MR-11).
@Suite("Diff styling")
struct DiffStylingTests {
    private static func line(_ kind: DiffLine.Kind, _ text: String) -> DiffLine {
        DiffLine(kind: kind, text: text, oldNumber: kind == .added ? nil : 1, newNumber: kind == .removed ? nil : 1)
    }

    private static func hunk(_ lines: [DiffLine]) -> DiffHunk {
        DiffHunk(oldStart: 1, oldCount: lines.count, newStart: 1, newCount: lines.count, lines: lines)
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
