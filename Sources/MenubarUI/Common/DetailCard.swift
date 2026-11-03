import SwiftUI

/// A card of a detail page: a headline with a symbol and a trailing accessory, such as a count or a button, over its
/// content, on a surface that lifts off the window: a faint white veil with a hairline edge in dark, a white card with a
/// hairline and a soft shadow in light.
///
/// The `width` is the page rule of every detail (MR, work item, build): compact fact cards flow in
/// ``CardColumnsLayout``'s columns, tall or growing ones (Description, Claude, Changes, Discussion) take the full width
/// below the columns, in the order they are declared.
struct DetailCard<Accessory: View, Content: View>: View {
    let title: String
    var symbol: String?
    /// the symbol's color; Claude's cards take its purple, the others a strong neutral
    var tint: Color?
    /// whether the card flows in the columns or spans the page
    var width: DetailCardWidth = .compact
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme

    /// the padding inside, in points
    static var padding: CGFloat { 16 }
    static var cornerRadius: CGFloat { 14 }

    var body: some View {
        let isDark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(symbolStyle)
                        .imageScale(.medium)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isDark ? Color(white: 1, opacity: 0.06) : Color.white, in: shape)
        .overlay {
            shape.strokeBorder(isDark ? Color(white: 1, opacity: 0.10) : Color.black.opacity(0.08), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(isDark ? 0 : 0.06), radius: 6, y: 1)
        .accessibilityElement(children: .contain)
        .layoutValue(key: DetailCardWidthKey.self, value: width)
    }

    private var symbolStyle: AnyShapeStyle {
        if let tint {
            return AnyShapeStyle(tint)
        }
        // Claude's cards share one mark, in Claude's purple.
        return symbol == "sparkles" ? AnyShapeStyle(.purple) : AnyShapeStyle(Color.primary.opacity(0.62))
    }
}

extension DetailCard where Accessory == EmptyView {
    init(
        _ title: String, symbol: String? = nil, tint: Color? = nil, width: DetailCardWidth = .compact,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.width = width
        accessory = EmptyView()
        self.content = content()
    }
}

extension DetailCard {
    init(
        _ title: String, symbol: String? = nil, tint: Color? = nil, width: DetailCardWidth = .compact,
        @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.width = width
        self.accessory = accessory()
        self.content = content()
    }
}

/// How a ``DetailCard`` sits on a detail page.
enum DetailCardWidth: Sendable {
    /// a short fact card (Reviewers, Approvals, Builds, Slot, Stages, Failed Tests…): flows in the columns
    case compact
    /// a tall or growing card (Description, Claude, Changes, Discussion): the full width, below the columns
    case fullWidth
}

struct DetailCardWidthKey: LayoutValueKey {
    static let defaultValue = DetailCardWidth.compact
}

/// The cards of a detail page: the compact ones in one column, or in two when there is room for two of `minColumnWidth`
/// and at least two cards to put there (each goes to the shorter column, so the columns end at about the same height);
/// then the full-width ones, stacked below the columns in the order they are declared. The cards keep their identity
/// when the columns change.
struct CardColumnsLayout: Layout {
    var minColumnWidth: CGFloat = 330
    var spacing: CGFloat = 22

    /// The arrangement for the last width asked, so the size and the placement of one layout pass measure the cards
    /// once: a detail page's cards are its most expensive views to measure.
    struct Cache {
        var width: CGFloat?
        var frames: [CGRect] = []
        var size: CGSize = .zero
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        arrange(width: proposal.width ?? minColumnWidth, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let frames = arrange(width: bounds.width, subviews: subviews, cache: &cache).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// No alignment guides of the cards' own: the default merges them, which places every card once more.
    func explicitAlignment(
        of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) -> CGFloat? {
        nil
    }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) -> CGFloat? {
        nil
    }

    private func arrange(width: CGFloat, subviews: Subviews, cache: inout Cache) -> (frames: [CGRect], size: CGSize) {
        if cache.width == width {
            return (cache.frames, cache.size)
        }
        // A stack around the page's scroll view asks it for its size at a width of zero, to learn how far it shrinks.
        // Measured there, every card laid its text out a character per line, the most expensive layout of a click;
        // the page never gets that narrow, so the cards answer at once.
        guard width > 0 else {
            return (Array(repeating: .zero, count: subviews.count), .zero)
        }
        let arranged = arrange(width: width, subviews: subviews)
        cache = Cache(width: width, frames: arranged.frames, size: arranged.size)
        return arranged
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let compact = subviews.indices.filter { subviews[$0][DetailCardWidthKey.self] == .compact }
        // Two columns when there is room for them and at least two compact cards that aren't empty; a lone compact card
        // takes the full width rather than half of it. The cards are measured at the column's width, and again at the
        // full width only when one column it is.
        let twoColumnWidth = (width - spacing) / 2
        var columns = 1
        var heights: [Int: CGFloat] = [:]
        if width >= minColumnWidth * 2 + spacing {
            for index in compact {
                heights[index] = subviews[index].sizeThatFits(ProposedViewSize(width: twoColumnWidth, height: nil)).height
            }
            if heights.values.count(where: { $0 > 0 }) >= 2 {
                columns = 2
            }
        }
        let columnWidth = columns == 2 ? twoColumnWidth : width
        if columns == 1 {
            for index in compact {
                heights[index] = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            }
        }
        var bottoms = Array(repeating: CGFloat(0), count: columns)
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        for index in compact {
            let height = heights[index] ?? 0
            let column = bottoms.indices.min { bottoms[$0] < bottoms[$1] } ?? 0
            frames[index] = CGRect(
                x: CGFloat(column) * (columnWidth + spacing), y: bottoms[column], width: columnWidth, height: height)
            // An empty card takes no room and no gap.
            if height > 0 {
                bottoms[column] += height + spacing
            }
        }
        var bottom = bottoms.max() ?? 0
        for index in subviews.indices where subviews[index][DetailCardWidthKey.self] != .compact {
            let height = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            frames[index] = CGRect(x: 0, y: bottom, width: width, height: height)
            if height > 0 {
                bottom += height + spacing
            }
        }
        return (frames, CGSize(width: width, height: max(0, bottom - spacing)))
    }
}

/// A fact of the header's chip strip: a symbol in its tint and a short text in a capsule. A chip that links or jumps is a
/// button that brightens on hover, and its tooltip, `help`, is required: it says what the click does ("Show build #4 in
/// Pipelines"), because a chip doesn't look like it does anything. A chip that only states a fact takes no action and
/// an optional tooltip.
struct DetailChip<Label: View>: View {
    var symbol: String?
    var tint: Color = .secondary
    private let help: String?
    private let action: (() -> Void)?
    private let label: Label

    @ViewState private var isHovered = false

    /// Returns a chip that does something when clicked.
    ///
    /// - Parameters:
    ///   - help: the tooltip, saying what the click does; never empty
    ///   - action: what the click does
    init(
        symbol: String?, tint: Color = .secondary, help: String, action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        assert(!help.isEmpty, "a clickable chip needs a tooltip that says what the click does")
        self.symbol = symbol
        self.tint = tint
        self.help = help
        self.action = action
        self.label = label()
    }

    /// Returns a chip that states a fact and does nothing when clicked.
    ///
    /// - Parameter help: the tooltip, if the chip's text needs more words
    init(symbol: String?, tint: Color = .secondary, help: String? = nil, @ViewBuilder label: () -> Label) {
        self.symbol = symbol
        self.tint = tint
        self.help = help
        action = nil
        self.label = label()
    }

    var body: some View {
        let content = HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
            }
            label
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(tint.opacity(isHovered ? 0.18 : 0.10), in: Capsule())
        .overlay { Capsule().strokeBorder(tint.opacity(isHovered ? 0.45 : 0.25), lineWidth: 0.5) }
        .contentShape(Capsule())
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .help(help ?? "")
        } else {
            content
                .help(help ?? "")
        }
    }
}

extension DetailChip where Label == Text {
    /// Returns a chip with a text that does something when clicked; `help` says what.
    init(symbol: String?, tint: Color = .secondary, text: String, help: String, action: @escaping () -> Void) {
        self.init(symbol: symbol, tint: tint, help: help, action: action) { Text(verbatim: text) }
    }

    /// Returns a chip with a text that states a fact.
    init(symbol: String?, tint: Color = .secondary, text: String, help: String? = nil) {
        self.init(symbol: symbol, tint: tint, help: help) { Text(verbatim: text) }
    }
}

/// A person as a round avatar with their initials, in a color of their own that stays the same between launches, with
/// an optional ring for me.
struct InitialsAvatar: View {
    let name: String
    /// the username, which picks the color
    let username: String
    var size: CGFloat = 22
    var isMe = false

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .mint, .cyan, .brown]

    var body: some View {
        let color = Self.color(of: username)
        Text(verbatim: Self.initials(of: name.isEmpty ? username : name))
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom), in: Circle())
            .padding(isMe ? 2 : 0)
            .overlay {
                if isMe {
                    Circle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                }
            }
            .accessibilityHidden(true)
    }

    /// "SL" for "Sam Lee", "AK" for "@akim"'s "Alex Kim", "J" for "jane"
    static func initials(of name: String) -> String {
        let words = name.replacingOccurrences(of: "(me)", with: "").split { $0 == " " || $0 == "@" || $0 == "." || $0 == "_" }
        let picked = words.count >= 2 ? [words[0], words[words.count - 1]] : Array(words.prefix(1))
        return String(picked.compactMap(\.first)).uppercased()
    }

    /// A color from the username's letters: `hashValue` changes with every launch.
    private static func color(of username: String) -> Color {
        let sum = username.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(sum % UInt32(palette.count))]
    }
}
