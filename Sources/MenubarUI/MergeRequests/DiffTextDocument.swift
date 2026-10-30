import Foundation
import MenubarCore

/// A file's diff as the text the diff view shows, one paragraph per row, and the way back from a range of characters to
/// the diff lines it touches (AI-07). Inline, one column; side by side, two (the old file, the new), whose rows line up.
///
/// A row's text is only the code: the numbers and the +/− signs are drawn beside it, so a selection copies the code alone.
/// No AppKit here, so that the mapping is tested without a window.
struct DiffTextDocument {
    /// What a row is.
    enum RowKind: Equatable {
        /// a hunk's `@@` line (side by side, its text is in the old column and the new one has an empty row)
        case header
        /// a line of the diff
        case line
        /// side by side, the side that has no line
        case blank
    }

    struct Row: Equatable {
        var kind: RowKind
        /// the code of a line, or the header's text; no newline in it
        var text: String
        /// the text in its syntax colors and changed parts, which add up to `text`
        var segments: [StyledLine.Segment]
        /// the line's name; `nil` for a header and a blank
        var id: DiffLineID?
        /// whether the line is added, removed or context; `nil` for a header and a blank
        var change: DiffLine.Kind?
        var oldNumber: Int?
        var newNumber: Int?
        var noNewlineAtEnd = false
    }

    /// The rows of one column and where each starts in the text, which is the rows' texts one per paragraph, each ended by
    /// a newline.
    struct Column: Equatable {
        var rows: [Row]
        /// the UTF-16 offset of each row's first character
        var starts: [Int]

        init(rows: [Row]) {
            self.rows = rows
            var offset = 0
            starts = rows.map { row in
                defer { offset += row.text.utf16.count + 1 }
                return offset
            }
        }

        /// the text of all rows, one paragraph each
        var text: String {
            rows.map { $0.text + "\n" }.joined()
        }

        /// the characters of a row with its newline
        func range(ofRow index: Int) -> NSRange {
            NSRange(location: starts[index], length: rows[index].text.utf16.count + 1)
        }
    }

    var layout: DiffLayoutChoice
    var columns: [Column]

    static let empty = DiffTextDocument(layout: .inline, columns: [Column(rows: [])])

    var rowCount: Int {
        columns.first?.rows.count ?? 0
    }

    // MARK: Building

    /// Returns the rows of the hunks' styled lines, a hunk's header and then its lines, up to `limit` rows in all.
    ///
    /// - Parameters:
    ///   - hunks: the file's hunks
    ///   - styled: each hunk's lines, styled
    ///   - layout: inline or side by side
    ///   - limit: the most rows, headers included
    static func make(hunks: [DiffHunk], styled: [[StyledLine]], layout: DiffLayoutChoice, limit: Int) -> DiffTextDocument {
        var inline: [Row] = []
        var left: [Row] = []
        var right: [Row] = []
        var count = 0
        for (hunk, lines) in zip(hunks, styled) {
            guard count < limit else {
                break
            }
            let header = header(of: hunk)
            count += 1
            switch layout {
            case .inline:
                inline.append(header)
                for line in lines.prefix(limit - count) {
                    inline.append(row(of: line))
                    count += 1
                }
            case .sideBySide:
                left.append(header)
                right.append(Row(kind: .header, text: "", segments: []))
                for split in DiffStyling.split(lines).prefix(limit - count) {
                    left.append(split.left.map(row(of:)) ?? blank)
                    right.append(split.right.map(row(of:)) ?? blank)
                    count += 1
                }
            }
        }
        return DiffTextDocument(
            layout: layout, columns: layout == .inline ? [Column(rows: inline)] : [Column(rows: left), Column(rows: right)])
    }

    private static let blank = Row(kind: .blank, text: "", segments: [])

    private static func header(of hunk: DiffHunk) -> Row {
        let text = sanitized(hunk.section.isEmpty ? hunk.header : "\(hunk.header) \(hunk.section)")
        return Row(kind: .header, text: text, segments: [.init(text: text)])
    }

    private static func row(of line: StyledLine) -> Row {
        var segments = line.segments.map { segment in
            StyledLine.Segment(text: sanitized(segment.text), token: segment.token, isChanged: segment.isChanged)
        }
        if segments.isEmpty, !line.line.text.isEmpty {
            segments = [.init(text: sanitized(line.line.text))]
        }
        return Row(
            kind: .line, text: segments.map(\.text).joined(), segments: segments, id: DiffLineID(line.line),
            change: line.line.kind, oldNumber: line.line.oldNumber, newNumber: line.line.newNumber,
            noNewlineAtEnd: line.line.noNewlineAtEnd)
    }

    /// The characters that end a paragraph in a text view would split a row in two: a carriage return (Windows line
    /// ends) goes, the others become a space.
    static func sanitized(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: Self.paragraphBreaks.contains) else {
            return text
        }
        return String(String.UnicodeScalarView(text.unicodeScalars.compactMap { scalar in
            scalar == "\r" ? nil : Self.paragraphBreaks.contains(scalar) ? " " : scalar
        }))
    }

    private static let paragraphBreaks: Set<Unicode.Scalar> = ["\r", "\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"]

    // MARK: From characters to lines

    /// A selection of characters in the diff: the rows it touches and the lines among them.
    struct TextPick: Equatable {
        /// the first and the last row touched, headers and blanks included
        var rows: ClosedRange<Int>
        /// the diff lines from the first line touched to the last, for "Ask Claude"
        var selection: DiffSelection
    }

    /// Returns the rows a range of characters touches in a column: a row counts when the range holds one of its
    /// characters, or its end of line when the row is empty, so a triple-click, which selects a line and its newline, is
    /// that line and not the next.
    ///
    /// - Parameters:
    ///   - range: the selected characters
    ///   - column: the column's index
    /// - Returns: the first and the last row; `nil` for an empty range or when nothing is touched
    func rows(touching range: NSRange, inColumn column: Int) -> ClosedRange<Int>? {
        guard range.length > 0, columns.indices.contains(column) else {
            return nil
        }
        let low = range.location
        let high = range.location + range.length
        let column = columns[column]
        var first: Int?
        var last: Int?
        for (index, row) in column.rows.enumerated() {
            let start = column.starts[index]
            let end = start + row.text.utf16.count
            if start >= high {
                break
            }
            let touched = end > start ? low < end : low <= start
            if touched {
                first = first ?? index
                last = index
            }
        }
        guard let first, let last else {
            return nil
        }
        return first...last
    }

    /// Returns the diff lines a selection of characters touches, as a pick of lines in the file.
    ///
    /// - Parameters:
    ///   - range: the selected characters
    ///   - column: the column's index
    ///   - path: the file's path
    /// - Returns: the pick; `nil` when no diff line is touched (a header alone, or a blank)
    func pick(of range: NSRange, inColumn column: Int, path: String) -> TextPick? {
        guard let rows = rows(touching: range, inColumn: column) else {
            return nil
        }
        let touched = columns[column].rows[rows]
        guard let first = touched.first(where: { $0.id != nil })?.id, let last = touched.last(where: { $0.id != nil })?.id else {
            return nil
        }
        return TextPick(rows: rows, selection: DiffSelection(path: path, anchor: first, head: last))
    }

    /// Returns the characters of the whole rows from one to another, in either order, each with its newline: what a press
    /// and drag over the line numbers selects.
    ///
    /// - Parameters:
    ///   - first: a row's index
    ///   - second: another row's index
    ///   - column: the column's index
    func characters(ofRows first: Int, _ second: Int, inColumn column: Int) -> NSRange {
        let column = columns[column]
        let low = column.range(ofRow: min(first, second))
        let high = column.range(ofRow: max(first, second))
        return NSRange(location: low.location, length: high.location + high.length - low.location)
    }

    /// Returns the selected code for ⌘C: the lines' code, without numbers, signs or hunk headers, a line cut where the
    /// selection starts or ends in it.
    ///
    /// - Parameters:
    ///   - range: the selected characters
    ///   - column: the column's index
    func code(in range: NSRange, inColumn column: Int) -> String {
        guard let rows = rows(touching: range, inColumn: column) else {
            return ""
        }
        let column = columns[column]
        var lines: [String] = []
        for index in rows where column.rows[index].kind == .line {
            let row = column.rows[index]
            let start = column.starts[index]
            let text = row.text as NSString
            let low = max(range.location - start, 0)
            let high = min(range.location + range.length - start, text.length)
            lines.append(high > low ? text.substring(with: NSRange(location: low, length: high - low)) : "")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Rows by position

    /// Returns the row at a vertical position, given each row's top and, last, the bottom of the rows: the row for a
    /// position above the first is the first, below the last the last.
    ///
    /// - Parameters:
    ///   - y: the position
    ///   - tops: the rows' tops in order, then the bottom of the last row; at least two values
    static func row(at y: CGFloat, tops: [CGFloat]) -> Int? {
        guard tops.count >= 2 else {
            return nil
        }
        var low = 0
        var high = tops.count - 2
        while low < high {
            let middle = (low + high + 1) / 2
            if tops[middle] <= y {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }
}
