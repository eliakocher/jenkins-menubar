import SwiftUI

/// Draws a ``MarkdownDocument`` in the detail's type: headings, paragraphs, bulleted, numbered and read-only task lists,
/// code on a soft fill, quotes behind a bar, tables in a hairline frame. The text can be selected; links open in the
/// browser, and only web links can open (WIN-02).
struct MarkdownView: View {
    let document: MarkdownDocument

    @AppStorage(MarkdownReadingSize.key) private var sizeStep = MarkdownReadingSize.defaultStep
    @Environment(\.openItemLink) private var openItemLink

    var body: some View {
        let scale = MarkdownReadingSize.scale(forStep: sizeStep)
        MarkdownBlocks(blocks: document.blocks, depth: 0)
            .environment(\.markdownScale, scale)
            // The macOS body size, so that 1× is what the text looked like before it could change; headings and code
            // below take their sizes from the same factor.
            .font(.system(size: MarkdownType.body * scale))
            .lineSpacing(MarkdownType.lineSpacing * (scale - 1))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            // The document makes no other links; this keeps any other scheme from reaching the system.
            .environment(\.openURL, OpenURLAction { [openItemLink] url in
                guard MarkdownDocument.isWebURL(url) else {
                    return .discarded
                }
                // A merge request or work item of the app's GitLab opens in the app, ⌥ aside (WIN-06).
                return MainActor.assumeIsolated { openItemLink.handle(url) } ? .handled : .systemAction
            })
    }
}

/// The macOS text styles' sizes, which the reading size scales (`Font.system(size:)` doesn't follow text styles).
enum MarkdownType {
    static let body: CGFloat = 13
    static let callout: CGFloat = 12
    static let title3: CGFloat = 15
    /// the extra room between lines at 2×, per unit of scale above 1×
    static let lineSpacing: CGFloat = 3
}

/// Blocks one under the other; a heading gets more room above it than the blocks between.
private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    /// how deep in lists and quotes, for the bullets
    let depth: Int

    @Environment(\.markdownScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: (depth == 0 ? 10 : 6) * scale) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index], depth: depth)
                    .padding(.top, index > 0 && blocks[index].isHeading ? 6 * scale : 0)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let depth: Int

    @Environment(\.markdownScale) private var scale

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text.styled)
                .font(Self.font(level, scale: scale))
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
            HStack(alignment: .top, spacing: 10 * scale) {
                Capsule()
                    .fill(.tertiary)
                    .frame(width: 3 * scale)
                MarkdownBlocks(blocks: blocks, depth: depth + 1)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let table):
            MarkdownTableView(table: table)
        case .rawText(let text):
            Text(verbatim: text)
                .font(.system(size: MarkdownType.callout * scale, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
                .padding(.vertical, 2 * scale)
        }
    }

    /// The templates' sections are `###`, so level 3 reads as a section header; 1 and 2 a step above, 4 to 6 below.
    private static func font(_ level: Int, scale: CGFloat) -> Font {
        let (size, weight): (CGFloat, Font.Weight) =
            switch level {
            case 1: (MarkdownType.title3, .bold)
            case 2: (MarkdownType.title3, .semibold)
            case 3: (MarkdownType.body, .bold)
            case 4: (MarkdownType.body, .semibold)
            default: (MarkdownType.callout, .semibold)
            }
        return .system(size: size * scale, weight: weight)
    }
}

/// A list: bullets that change with the depth, right-aligned numbers, or read-only check boxes.
private struct MarkdownListView: View {
    let list: MarkdownList
    let depth: Int

    @Environment(\.markdownScale) private var scale

    private static let bullets = ["•", "◦", "▪︎"]

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            ForEach(list.items.indices, id: \.self) { index in
                let item = list.items[index]
                HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
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
                .frame(minWidth: 16 * scale, alignment: .trailing)
        } else {
            Text(verbatim: Self.bullets[depth % Self.bullets.count])
                .foregroundStyle(.secondary)
                .frame(width: 10 * scale)
        }
    }
}

/// Code in a monospaced font on a soft rounded fill; long lines scroll sideways rather than wrap.
private struct MarkdownCodeView: View {
    let code: String

    @Environment(\.markdownScale) private var scale

    var body: some View {
        ScrollView(.horizontal) {
            Text(verbatim: code)
                .font(.system(size: MarkdownType.callout * scale, design: .monospaced))
                .fixedSize()
                .padding(.horizontal, 10 * scale)
                .padding(.vertical, 8 * scale)
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

    @Environment(\.markdownScale) private var scale

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14 * scale, verticalSpacing: 6 * scale) {
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
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 8 * scale)
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
