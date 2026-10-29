import SwiftUI

/// Draws a ``MarkdownDocument`` in the detail's type: headings, paragraphs, bulleted, numbered and read-only task lists,
/// code on a soft fill, quotes behind a bar, tables in a hairline frame. The text can be selected; links open in the
/// browser, and only web links can open (WIN-02).
struct MarkdownView: View {
    let document: MarkdownDocument

    var body: some View {
        MarkdownBlocks(blocks: document.blocks, depth: 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            // The document makes no other links; this keeps any other scheme from reaching the system.
            .environment(\.openURL, OpenURLAction { url in
                MarkdownDocument.isWebURL(url) ? .systemAction : .discarded
            })
    }
}

/// Blocks one under the other; a heading gets more room above it than the blocks between.
private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    /// how deep in lists and quotes, for the bullets
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: depth == 0 ? 10 : 6) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index], depth: depth)
                    .padding(.top, index > 0 && blocks[index].isHeading ? 6 : 0)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let depth: Int

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text.styled)
                .font(Self.font(level))
                .foregroundStyle(level >= 5 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(text.styled)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let list):
            MarkdownListView(list: list, depth: depth)
        case .code(_, let code):
            MarkdownCodeView(code: code)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(.tertiary)
                    .frame(width: 3)
                MarkdownBlocks(blocks: blocks, depth: depth + 1)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let table):
            MarkdownTableView(table: table)
        case .rawText(let text):
            Text(verbatim: text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
                .padding(.vertical, 2)
        }
    }

    /// The templates' sections are `###`, so level 3 reads as a section header; 1 and 2 a step above, 4 to 6 below.
    private static func font(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.bold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        case 4: .body.weight(.semibold)
        default: .callout.weight(.semibold)
        }
    }
}

/// A list: bullets that change with the depth, right-aligned numbers, or read-only check boxes.
private struct MarkdownListView: View {
    let list: MarkdownList
    let depth: Int

    private static let bullets = ["•", "◦", "▪︎"]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(list.items.indices, id: \.self) { index in
                let item = list.items[index]
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(item, number: list.start + index)
                    MarkdownBlocks(blocks: item.blocks, depth: depth + 1)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: MarkdownList.Item, number: Int) -> some View {
        if let isChecked = item.isChecked {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .foregroundStyle(isChecked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityLabel(isChecked ? "Done" : "Not done")
        } else if list.isOrdered {
            Text(verbatim: "\(String(number)).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
        } else {
            Text(verbatim: Self.bullets[depth % Self.bullets.count])
                .foregroundStyle(.secondary)
                .frame(width: 10)
        }
    }
}

/// Code in a monospaced font on a soft rounded fill; long lines scroll sideways rather than wrap.
private struct MarkdownCodeView: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(verbatim: code)
                .font(.system(.callout, design: .monospaced))
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        // The overlay scroller sat on the code as a grey blob; a trackpad or Shift and the wheel still scroll.
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: .rect(cornerRadius: 8))
    }
}

/// A table: the header row in semibold, hairlines between the rows, in a rounded hairline frame. The cells wrap.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    cell(table.header[column], column: column)
                        .fontWeight(.semibold)
                }
            }
            ForEach(table.rows.indices, id: \.self) { index in
                Divider()
                    .opacity(index == 0 ? 1 : 0.5)
                GridRow {
                    ForEach(table.rows[index].indices, id: \.self) { column in
                        cell(table.rows[index][column], column: column)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator)
        }
    }

    private func cell(_ text: AttributedString, column: Int) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        return Text(text.styled)
            .multilineTextAlignment(alignment.text)
            .fixedSize(horizontal: false, vertical: true)
            .gridColumnAlignment(alignment.horizontal)
    }
}

extension MarkdownTable.Alignment {
    fileprivate var horizontal: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    fileprivate var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

extension MarkdownBlock {
    fileprivate var isHeading: Bool {
        if case .heading = self {
            return true
        }
        return false
    }
}

extension AttributedString {
    /// the text with its inline code on a faint fill; Text draws the code itself in a monospaced font
    fileprivate var styled: AttributedString {
        var text = self
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].swiftUI.backgroundColor = Color.secondary.opacity(0.14)
        }
        return text
    }
}
