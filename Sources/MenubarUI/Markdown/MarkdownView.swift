import AppKit
import SwiftUI

/// Draws a ``MarkdownDocument`` in the app's reading type (WIN-02): a heading hierarchy, bulleted, numbered and read-only
/// task lists with hanging indents, code blocks in their language's colors with Copy, tables with a header row and
/// zebra rows that scroll sideways when wide, quotes and callouts behind a colored rule, references and mentions as
/// chips. The text can be selected; only web links open, and a link to one of the app's builds, merge requests or work
/// items opens in the app (⌥ the browser, WIN-06).
///
/// The document comes styled from ``MarkdownDocument/rendered(_:base:)``, parsed once per text: `body` does no parsing.
struct MarkdownView: View {
    let document: MarkdownDocument

    @AppStorage(MarkdownReadingSize.key) private var sizeStep = MarkdownReadingSize.defaultStep
    @Environment(\.openItemLink) private var openItemLink

    init(document: MarkdownDocument) {
        self.document = document
    }

    /// the text's document from ``MarkdownCache``
    init(markdown: String, base: URL?) {
        document = MarkdownDocument.rendered(markdown, base: base)
    }

    var body: some View {
        let scale = MarkdownReadingSize.scale(forStep: sizeStep)
        MarkdownBlocks(blocks: document.blocks, depth: 0)
            .environment(\.markdownScale, scale)
            // The macOS body size, so that 1× is what the text looked like before it could change; headings and code
            // below take their sizes from the same factor.
            .font(.system(size: MarkdownType.body * scale))
            .lineSpacing(MarkdownType.lineSpacing(scale))
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

    /// The room between lines: a little at 1× so that long answers read easily, more as the text grows.
    static func lineSpacing(_ scale: CGFloat) -> CGFloat {
        1.5 * scale + 3 * (scale - 1)
    }
}

/// Blocks one under the other; a heading gets more room above it than the blocks between, the higher the more.
private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    /// how deep in lists and quotes, for the bullets
    let depth: Int

    @Environment(\.markdownScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: (depth == 0 ? 10 : 6) * scale) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index], depth: depth)
                    .padding(.top, index > 0 ? blocks[index].roomAbove * scale : 0)
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
            MarkdownHeading(level: level, text: text)
        case .paragraph(let text):
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let list):
            MarkdownListView(list: list, depth: depth)
        case .code(let language, let code):
            MarkdownCodeView(language: language, code: code)
        case .quote(let blocks):
            MarkdownQuoteView(tint: .accentColor, depth: depth) {
                MarkdownBlocks(blocks: blocks, depth: depth + 1)
                    .foregroundStyle(.secondary)
            }
        case .callout(let kind, let blocks):
            MarkdownQuoteView(tint: kind.tint, depth: depth, isCallout: true) {
                VStack(alignment: .leading, spacing: 4 * scale) {
                    Label(kind.title, systemImage: kind.symbol)
                        .font(.system(size: MarkdownType.body * scale, weight: .semibold))
                        .foregroundStyle(kind.tint)
                    MarkdownBlocks(blocks: blocks, depth: depth + 1)
                }
            }
        case .table(let table):
            MarkdownTableView(table: table)
        case .rawText(let text):
            Text(verbatim: text)
                .font(.system(size: MarkdownType.callout * scale, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
                .padding(.vertical, 4 * scale)
        }
    }
}

/// A heading: the templates' sections are `###`, so level 3 reads as a section header; 1 and 2 a step above with a
/// hairline under them, 4 to 6 below, 5 and 6 in a quieter color.
private struct MarkdownHeading: View {
    let level: Int
    let text: AttributedString

    @Environment(\.markdownScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            Text(text)
                .font(.system(size: size * scale, weight: weight))
                .foregroundStyle(level >= 5 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if level <= 2 {
                Rectangle()
                    .fill(.separator.opacity(level == 1 ? 1 : 0.7))
                    .frame(height: 1)
            }
        }
    }

    private var size: CGFloat {
        switch level {
        case 1: MarkdownType.title3 + 3
        case 2: MarkdownType.title3 + 0.5
        case 3: MarkdownType.body + 1
        case 4: MarkdownType.body
        default: MarkdownType.callout
        }
    }

    private var weight: Font.Weight {
        switch level {
        case 1: .bold
        case 2, 3: .semibold
        default: .semibold
        }
    }
}

/// A list: bullets that change with the depth, numbers aligned on their dot, or read-only check boxes, each in a column
/// of its own so that wrapped lines hang under the text.
private struct MarkdownListView: View {
    let list: MarkdownList
    let depth: Int

    @Environment(\.markdownScale) private var scale

    private static let bullets = ["•", "◦", "▪︎"]

    var body: some View {
        let width = markerWidth
        VStack(alignment: .leading, spacing: 4 * scale) {
            ForEach(list.items.indices, id: \.self) { index in
                let item = list.items[index]
                HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
                    marker(item, number: list.start + index)
                        .frame(width: width, alignment: list.isOrdered && item.isChecked == nil ? .trailing : .center)
                    MarkdownBlocks(blocks: item.blocks, depth: depth + 1)
                        .foregroundStyle(item.isChecked == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
            }
        }
    }

    /// the marker column: as wide as the longest number, a check box or a bullet
    private var markerWidth: CGFloat {
        if list.items.contains(where: { $0.isChecked != nil }) {
            return 16 * scale
        }
        if list.isOrdered {
            let digits = String(list.start + max(list.items.count - 1, 0)).count
            return (CGFloat(digits) * 7.5 + 5) * scale
        }
        return 10 * scale
    }

    @ViewBuilder
    private func marker(_ item: MarkdownList.Item, number: Int) -> some View {
        if let isChecked = item.isChecked {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .foregroundStyle(isChecked ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                .accessibilityLabel(isChecked ? "Done" : "Not done")
        } else if list.isOrdered {
            Text(verbatim: "\(String(number)).")
                .monospacedDigit()
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        } else {
            Text(verbatim: Self.bullets[depth % Self.bullets.count])
                .fontWeight(.heavy)
                .foregroundStyle(depth == 0 ? AnyShapeStyle(Color.accentColor.opacity(0.85)) : AnyShapeStyle(.tertiary))
        }
    }
}

/// A quote or callout: its blocks behind a colored rule on a faint wash of the same color.
private struct MarkdownQuoteView<Content: View>: View {
    let tint: Color
    let depth: Int
    var isCallout = false
    @ViewBuilder var content: Content

    @Environment(\.markdownScale) private var scale

    var body: some View {
        content
            .padding(.leading, 12 * scale)
            .padding(.trailing, 10 * scale)
            .padding(.vertical, (isCallout ? 8 : 6) * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                ZStack(alignment: .leading) {
                    tint.opacity(isCallout ? 0.09 : 0.05)
                    tint.opacity(isCallout ? 0.9 : 0.55)
                        .frame(width: 3 * scale)
                }
            }
            .clipShape(.rect(cornerRadius: 6 * scale, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Code in a monospaced font on a soft rounded fill, in its language's colors; long lines scroll sideways rather than
/// wrap. A block with a language has a header with its name and Copy; one without shows Copy on hover.
private struct MarkdownCodeView: View {
    let language: String?
    let code: String

    @Environment(\.markdownScale) private var scale
    @ViewState private var isHovering = false
    @ViewState private var copied = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                HStack(spacing: 6) {
                    Text(verbatim: language.lowercased())
                        .font(.system(size: MarkdownType.callout * scale - 1, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    copyButton
                }
                .padding(.leading, 12 * scale)
                .padding(.trailing, 6 * scale)
                .padding(.vertical, 4 * scale)
                .background(.fill.quaternary)
                Rectangle()
                    .fill(.separator.opacity(0.6))
                    .frame(height: 1)
            }
            ScrollView(.horizontal) {
                Text(MarkdownCache.highlighted(code, language: language))
                    .font(.system(size: MarkdownType.callout * scale, design: .monospaced))
                    .lineSpacing(2 * scale)
                    .fixedSize()
                    .padding(.horizontal, 12 * scale)
                    .padding(.vertical, 9 * scale)
            }
            // The overlay scroller sat on the code as a grey blob; a trackpad or Shift and the wheel still scroll.
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topTrailing) {
                if language == nil, isHovering || copied {
                    copyButton
                        .padding(.horizontal, 4)
                        .background(.regularMaterial, in: .rect(cornerRadius: 6, style: .continuous))
                        .padding(5 * scale)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary.opacity(0.7), in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator.opacity(0.7)))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .font(.system(size: MarkdownType.callout * scale - 1))
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
        .opacity(language == nil || isHovering || copied ? 1 : 0.6)
        .help("Copy the code")
    }
}

/// A table: a tinted header row in semibold, hairlines and faint zebra rows, in a rounded hairline frame. The cells
/// wrap while every column keeps a readable width; a table wider than that scrolls sideways.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    @Environment(\.markdownScale) private var scale

    /// the narrowest a column gets before the table scrolls instead
    private var minimumColumnWidth: CGFloat { 90 * scale }
    /// a column's width in a table that scrolls
    private var scrollingColumnWidth: CGFloat { 150 * scale }

    var body: some View {
        let columns = CGFloat(max(table.alignments.count, 1))
        ViewThatFits(in: .horizontal) {
            // As wide as its text when that fits, as GitLab draws it; else the width it gets, wrapping.
            grid
                .fixedSize(horizontal: true, vertical: false)
            grid
                .frame(minWidth: 0, idealWidth: columns * minimumColumnWidth, maxWidth: .infinity, alignment: .leading)
            // Too many columns for the width: each gets a readable width, and the table scrolls sideways.
            ScrollView(.horizontal) {
                grid
                    .frame(width: columns * scrollingColumnWidth)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var grid: some View {
        let shape = RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    cell(table.header[column], column: column)
                        .fontWeight(.semibold)
                        .background(.fill.tertiary)
                }
            }
            ForEach(table.rows.indices, id: \.self) { index in
                Rectangle()
                    .fill(.separator.opacity(index == 0 ? 1 : 0.5))
                    .frame(height: 1)
                    .gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(table.rows[index].indices, id: \.self) { column in
                        cell(table.rows[index][column], column: column)
                            .background(index.isMultiple(of: 2) ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.fill.quinary))
                    }
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cell(_ text: AttributedString, column: Int) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        return Text(text)
            .multilineTextAlignment(alignment.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10 * scale)
            .padding(.vertical, 6 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment.frame)
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

    fileprivate var frame: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

extension MarkdownCallout {
    fileprivate var tint: Color {
        switch self {
        case .note: .blue
        case .tip: .green
        case .important: .purple
        case .warning: .orange
        case .caution: .red
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .note: "info.circle.fill"
        case .tip: "lightbulb.fill"
        case .important: "exclamationmark.bubble.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .caution: "exclamationmark.octagon.fill"
        }
    }
}

extension MarkdownBlock {
    /// the extra room above the block, at 1×: more above a higher heading
    fileprivate var roomAbove: CGFloat {
        guard case .heading(let level, _) = self else {
            return 0
        }
        return level <= 2 ? 10 : level == 3 ? 6 : 3
    }
}
