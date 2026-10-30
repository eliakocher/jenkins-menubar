import SwiftUI

/// A card of a detail page: a headline with a symbol and a trailing accessory, such as a count or a button, over its
/// content, on a surface that lifts off the window: a faint white veil with a hairline edge in dark, a white card with a
/// hairline and a soft shadow in light. The card tells ``SectionNav`` its title, and is where the nav jumps to.
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
        .id(SectionTarget(title: title))
        .preference(key: SectionTitlesKey.self, value: [title])
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? minColumnWidth, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let isCompact = { (subview: LayoutSubview) in subview[DetailCardWidthKey.self] == .compact }
        // A lone compact card takes the full width rather than half of it.
        let compactCount = subviews.filter {
            isCompact($0) && $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height > 0
        }.count
        let columns = width >= minColumnWidth * 2 + spacing && compactCount >= 2 ? 2 : 1
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var heights = Array(repeating: CGFloat(0), count: columns)
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        for (index, subview) in subviews.enumerated() where isCompact(subview) {
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            frames[index] = CGRect(
                x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: height)
            // An empty card takes no room and no gap.
            if height > 0 {
                heights[column] += height + spacing
            }
        }
        var bottom = heights.max() ?? 0
        for (index, subview) in subviews.enumerated() where !isCompact(subview) {
            let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            frames[index] = CGRect(x: 0, y: bottom, width: width, height: height)
            if height > 0 {
                bottom += height + spacing
            }
        }
        return (frames, CGSize(width: width, height: max(0, bottom - spacing)))
    }
}

/// A fact of the header's chip strip: a symbol in its tint and a short text in a capsule, a button where it links or
/// jumps, which brightens on hover.
struct DetailChip<Label: View>: View {
    var symbol: String?
    var tint: Color = .secondary
    var help: String?
    var action: (() -> Void)?
    @ViewBuilder var label: Label

    @ViewState private var isHovered = false

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
    init(symbol: String?, tint: Color = .secondary, text: String, help: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.tint = tint
        self.help = help
        self.action = action
        label = Text(verbatim: text)
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
