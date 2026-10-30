import AppKit
import MenubarCore
import SwiftUI

/// A label as a pill in GitLab's colors (`docs/design/work-items.md`, Label pills; WI-06), app-defined since the
/// system's token is an input (Departure 3).
/// - Plain: a capsule filled with the color, the text black or white by WI-06's rule.
/// - Scoped: the scope filled with the color, the value on the row's background in the label color, the capsule
///   stroked in the color.
/// - No known color: the secondary fill, the label color.
///
/// Every pill has a hairline in the separator color, so white and black labels keep their shape. One line, at most the
/// row's width, cut in the middle; its tooltip is the full title. The title is plain text, never markup (WI-04).
///
/// The slot pills show the value alone, one capsule filled with the color, to save room (the user, 2026-10-29): the
/// compact one sits in a list row's line next to the title, in a smaller font with tighter padding; the value one in
/// the detail's facts line. The detail's Labels section keeps the full pills.
struct LabelPill: View {
    /// How much of the label a pill shows.
    enum Style {
        /// the title, a scoped label's scope and value apart
        case full
        /// the value alone, like "2026.51" for `cDueSlot::2026.51`
        case value
        /// the value alone, smaller, for a list row's line
        case compact
    }

    let label: LabelPillModel
    var style = Style.full
    /// the compact font and padding for any style: the detail header's quiet labels
    var small = false

    private var compact: Bool { style == .compact || small }

    var body: some View {
        content
            .font(compact ? .caption : .subheadline)
            .lineLimit(1)
            .truncationMode(.middle)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .help(label.title)
    }

    private var edge: CGFloat { compact ? 6 : 8 }
    private var inner: CGFloat { compact ? 4 : 5 }
    private var vertical: CGFloat { compact ? 1 : 2 }

    @ViewBuilder private var content: some View {
        if style != .full {
            Text(verbatim: label.shortTitle)
                .foregroundStyle(label.color == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(textColor))
                .padding(.horizontal, edge)
                .padding(.vertical, vertical)
                .background(label.color.map { AnyShapeStyle(Self.color(hex: $0)) } ?? AnyShapeStyle(.fill.secondary))
        } else if let color = label.color.map(Self.color(hex:)), let scope = label.scope, let value = label.value {
            HStack(spacing: 0) {
                Text(verbatim: scope)
                    .foregroundStyle(textColor)
                    .padding(.leading, edge)
                    .padding(.trailing, inner)
                    .padding(.vertical, vertical)
                    .background(color)
                // The value gives way last: it says what the label is set to.
                Text(verbatim: value)
                    .foregroundStyle(.primary)
                    .padding(.leading, inner)
                    .padding(.trailing, edge)
                    .padding(.vertical, vertical)
                    .layoutPriority(1)
            }
            .overlay {
                Capsule()
                    .strokeBorder(color, lineWidth: 1)
            }
        } else if let color = label.color.map(Self.color(hex:)) {
            Text(verbatim: label.title)
                .foregroundStyle(textColor)
                .padding(.horizontal, edge)
                .padding(.vertical, vertical)
                .background(color)
        } else {
            Text(verbatim: label.title)
                .foregroundStyle(.primary)
                .padding(.horizontal, edge)
                .padding(.vertical, vertical)
                .background(.fill.secondary)
        }
    }

    /// Black or white on the label's color (WI-06's rule; Departure 5)
    private var textColor: Color {
        label.color.flatMap(Label.textColor(onBackground:)) == "#000000" ? .black : .white
    }

    private static func color(hex: String) -> Color {
        Color(nsColor: NSColor(hex: hex))
    }
}

/// Lays pills out in lines, as text wraps: each at its ideal width, at most the container's, the next one on a new line
/// when it doesn't fit (`docs/design/work-items.md`, Unverified 2).
struct PillFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: proposal.width ?? bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// Returns each pill's frame and the size of them all.
    ///
    /// - Parameters:
    ///   - width: the room in a line; `nil` puts every pill on one line
    ///   - subviews: the pills
    private func arrange(width: CGFloat?, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let room = width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > room {
                // A pill wider than the row is cut to the row.
                size = subview.sizeThatFits(ProposedViewSize(width: room, height: nil))
                size.width = min(size.width, room)
            }
            if x > 0, x + size.width > room {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (frames, CGSize(width: width.map { min($0, widest) } ?? widest, height: y + lineHeight))
    }
}
