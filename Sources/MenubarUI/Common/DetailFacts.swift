import AppKit
import SwiftUI

/// A detail header's aside (``DetailHeader``'s `aside`): the item's facts as lines, a quiet name and its value, on a
/// faint panel, as an inspector has them; in two columns when there is room (``DetailFactColumns``). Each line is a ``DetailFactRow``; a panel without lines is left out by its
/// caller, so the header's main part gets the full width.
struct DetailFactsPanel<Content: View>: View {
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        DetailFactColumns {
            content
        }
        .padding(.horizontal, DetailFactColumns.panelPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colorScheme == .dark ? Color(white: 1, opacity: 0.04) : Color.black.opacity(0.025), in: shape)
        .overlay {
            shape.strokeBorder(colorScheme == .dark ? Color(white: 1, opacity: 0.08) : Color.black.opacity(0.07), lineWidth: 0.5)
        }
    }
}

/// One line of a ``DetailFactsPanel``: the name, quiet, in a column of its own, and the value, which wraps.
struct DetailFactRow<Value: View>: View {
    let name: String
    @ViewBuilder var value: Value

    /// the names' column: room for two words, like "Prerequisite status", on one line
    static var nameWidth: CGFloat { 128 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: name)
                .foregroundStyle(.secondary)
                .frame(width: Self.nameWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

/// A fact's value as text after a small dot in its label's GitLab color, as the system's tags have it; the tooltip says
/// which labels it comes from.
struct DetailFactValue: View {
    let text: String
    /// GitLab's color, `#rrggbb`; `nil` draws a grey dot
    var color: String?
    var help: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(color.map { AnyShapeStyle(Color(nsColor: NSColor(hex: $0))) } ?? AnyShapeStyle(.tertiary))
                .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
                .frame(width: 8, height: 8)
                // On the text's middle, not its baseline.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
            Text(verbatim: text)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(help ?? "")
    }
}

/// The lines of a ``DetailFactsPanel``: as many columns of at least `minColumnWidth` as the width has room for, up to
/// two, the lines filling the first column, then the next, so they read down as one list; each column keeps the names
/// and the values aligned.
struct DetailFactColumns: Layout {
    var minColumnWidth: CGFloat = Self.minColumnWidth
    var spacing: CGFloat = 10
    var columnGap: CGFloat = Self.columnGap

    static let minColumnWidth: CGFloat = 280
    static let columnGap: CGFloat = 28
    /// the most columns, however wide: three took the room the title needs and wrapped it (the user, 2026-11-03)
    static let maxColumns = 2

    /// the panel's padding on each side
    static let panelPadding: CGFloat = 14

    /// Returns the least width of a ``DetailFactsPanel`` whose lines take `columns` columns.
    static func panelWidth(columns: Int) -> CGFloat {
        CGFloat(columns) * minColumnWidth + CGFloat(columns - 1) * columnGap + panelPadding * 2
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(width: proposal.width, subviews: subviews)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(width: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> [CGRect] {
        guard let width, width > 0 else {
            var y: CGFloat = 0
            return subviews.map { subview in
                let size = subview.sizeThatFits(.unspecified)
                defer { y += size.height + spacing }
                return CGRect(origin: CGPoint(x: 0, y: y), size: size)
            }
        }
        let fitting = Int(((width + columnGap) / (minColumnWidth + columnGap)).rounded(.down))
        let columns = max(1, min(Self.maxColumns, subviews.count, fitting))
        let columnWidth = (width - columnGap * CGFloat(columns - 1)) / CGFloat(columns)
        let perColumn = (subviews.count + columns - 1) / columns
        var bottoms = Array(repeating: CGFloat(0), count: columns)
        return subviews.indices.map { index in
            let column = min(index / max(perColumn, 1), columns - 1)
            let height = subviews[index].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let frame = CGRect(
                x: CGFloat(column) * (columnWidth + columnGap), y: bottoms[column], width: columnWidth, height: height)
            bottoms[column] += height + spacing
            return frame
        }
    }
}
