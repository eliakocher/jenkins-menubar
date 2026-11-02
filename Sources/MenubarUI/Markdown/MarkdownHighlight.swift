import Foundation
import SwiftUI

/// The words of a search, marked in a ``MarkdownDocument`` (AI-04: the search field in Digest).
extension MarkdownDocument {
    /// Returns the document with every occurrence of the query's words on a yellow fill, and how many there are.
    ///
    /// Words are what whitespace separates; case and accents don't matter. Headings, paragraphs, list items, quotes
    /// and table cells are searched, inline code too; fenced code and raw HTML are not.
    ///
    /// - Parameter query: the search field's text; blank marks nothing
    /// - Returns: the document with the marks, and the number of marks
    func highlighting(_ query: String) -> (document: MarkdownDocument, matches: Int) {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            return (self, 0)
        }
        var marker = Marker(words: words)
        let blocks = blocks.map { marker.mark($0) }
        return (MarkdownDocument(blocks: blocks), marker.count)
    }

    /// Marks the words in the blocks' inline text and counts them.
    private struct Marker {
        let words: [String]
        var count = 0

        mutating func mark(_ block: MarkdownBlock) -> MarkdownBlock {
            switch block {
            case .heading(let level, let text):
                return .heading(level: level, mark(text))
            case .paragraph(let text):
                return .paragraph(mark(text))
            case .list(var list):
                list.items = list.items.map { item in
                    var item = item
                    item.blocks = item.blocks.map { mark($0) }
                    return item
                }
                return .list(list)
            case .quote(let blocks):
                return .quote(blocks.map { mark($0) })
            case .table(var table):
                table.header = table.header.map { mark($0) }
                table.rows = table.rows.map { $0.map { mark($0) } }
                return .table(table)
            case .code, .rawText, .rule:
                return block
            }
        }

        private mutating func mark(_ text: AttributedString) -> AttributedString {
            var marked = text
            for word in words {
                var start = marked.startIndex
                while start < marked.endIndex, let found = marked[start...].range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                    marked[found].swiftUI.backgroundColor = Color.yellow.opacity(0.5)
                    count += 1
                    start = found.upperBound
                }
            }
            return marked
        }
    }
}
