import SwiftUI

/// The shape the window's content lists share (Task 7.0, the user, 2026-10-30: "other views are a bit ugly and don't use
/// all the width"): the Pipelines, Merge Requests and Work Items rows put the same things in the same places, so the
/// three lists read alike and use the column's whole width.
///
/// - The symbol column on the left, 16 pt, first-baseline aligned with the title. It is optional: a list with no symbol
///   to show (Work Items) has no column, and the text starts at the row's leading edge.
/// - Line 1: the title in up to two lines, then cut; at the right end the quiet marks and the time ("5m ago"). They keep
///   their width, so the title gives way, never the time.
/// - Line 2: the facts in the secondary style, cut at the end or dropping their least important parts first
///   (``DetailsLine``).
/// - More lines below, like a build's progress bar, in the same column.
struct ListRow<Symbol: View, Trailing: View, Details: View>: View {
    /// the title; its tooltip is the whole title
    let title: String
    private let symbol: Symbol
    /// whether the row has the symbol column; without it the text starts at the leading edge
    private let hasSymbol: Bool
    /// the marks and the time at line 1's right end, in a row of their own
    private let trailing: Trailing
    private let details: Details
    @Environment(\.dynamicTypeSize) private var typeSize

    /// A row with a symbol column.
    ///
    /// - Parameters:
    ///   - title: the title
    ///   - symbol: the status symbol, in the 16 pt column
    ///   - trailing: the marks and the time at line 1's right end
    ///   - details: line 2 and the lines below
    init(
        title: String, @ViewBuilder symbol: () -> Symbol, @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder details: () -> Details
    ) {
        self.title = title
        self.symbol = symbol()
        hasSymbol = true
        self.trailing = trailing()
        self.details = details()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ListRowMetrics.gap) {
            if hasSymbol {
                symbol
                    .frame(width: ListRowMetrics.symbolColumn)
            }
            VStack(alignment: .leading, spacing: ListRowMetrics.lineSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: ListRowMetrics.gap) {
                    // From accessibility1 on, titles take up to three lines and the details wrap.
                    Text(verbatim: title)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : ListRowMetrics.titleLines)
                        .help(title)
                    Spacer(minLength: 0)
                    trailing
                }
                details
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        // The separator starts at the title in every list: after the symbol column, or at the edge without one.
        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
            hasSymbol ? ListRowMetrics.symbolColumn + ListRowMetrics.gap : dimensions[.leading]
        }
    }
}

extension ListRow where Symbol == EmptyView {
    /// A row without a symbol column: the text starts at the row's leading edge.
    ///
    /// - Parameters:
    ///   - title: the title
    ///   - trailing: the marks and the time at line 1's right end
    ///   - details: line 2 and the lines below
    init(title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder details: () -> Details) {
        self.title = title
        symbol = EmptyView()
        hasSymbol = false
        self.trailing = trailing()
        self.details = details()
    }
}

/// The metrics of ``ListRow``, the same in every list.
enum ListRowMetrics {
    /// the symbol column of the rows that have a symbol
    static let symbolColumn: CGFloat = 16
    /// the space between the columns and between line 1's parts
    static let gap: CGFloat = 6
    /// the space between a row's lines
    static let lineSpacing: CGFloat = 2
    /// how many lines a title takes before it is cut
    static let titleLines = 2
}

/// The time at a row's right end: "5m ago", quiet and never cut.
struct ListRowTime: View {
    let text: String
    /// the tooltip; `nil` for none
    var help: String?

    var body: some View {
        Text(verbatim: text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .help(help ?? "")
    }
}

/// A row's facts line: the lead always, and parts after it that drop from the end when the line is short of room, so a
/// narrow column keeps what identifies the row and a wide one shows everything. The lead is cut at the end only when even
/// it doesn't fit. At accessibility sizes the line wraps whole instead.
struct DetailsLine: View {
    /// what stays: "!21 · Ready to merge"
    let lead: String
    /// what follows, in order, at most three; the last one goes first
    let more: [String]
    /// the start of `lead` that is a reference, like "web!8", which the last resort cuts in the middle so its number stays
    /// and keeps the rest of `lead`; `nil` cuts `lead` at the end
    var reference: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            Text(verbatim: line(more.count))
        } else {
            ViewThatFits(in: .horizontal) {
                whole(3)
                whole(2)
                whole(1)
                leastLine
            }
        }
    }

    @ViewBuilder private var leastLine: some View {
        if let reference, lead.hasPrefix(reference) {
            PanelLineLayout {
                Text(verbatim: reference)
                    .truncationMode(.middle)
                    .panelLineCap(0.6)
                Text(verbatim: String(lead.dropFirst(reference.count)))
            }
            .lineLimit(1)
        } else {
            Text(verbatim: lead)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// The line with the first `count` parts after the lead, at its natural width, so `ViewThatFits` can tell whether it fits.
    @ViewBuilder
    private func whole(_ count: Int) -> some View {
        Text(verbatim: line(count))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func line(_ count: Int) -> String {
        ([lead] + more.prefix(count)).joined(separator: " · ")
    }
}
