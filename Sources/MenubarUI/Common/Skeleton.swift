import SwiftUI

/// The app's loading rule, for every screen: show what you know, skeleton what's loading, never a blank page.
///
/// A header, row or card the app already has facts for shows them at once (a reference, a title, a state, an author);
/// only the part still on its way is a skeleton (``SkeletonBlock``, ``SkeletonLines``, ``SkeletonRows``,
/// ``SkeletonCard``, ``SkeletonHeader``), in the shape and about the height of what replaces it, so nothing jumps when
/// the data arrives. The pieces shimmer softly (about 1.2 s) and sit still under Reduce Motion. A spinner stays only
/// where a control's own action runs, such as a button or a re-request, and an error keeps its message with "Try Again".
/// The type holds the look of every piece.
enum Skeleton {
    /// the length of one shimmer sweep, in seconds
    static let cycle: TimeInterval = 1.2

    /// the bars' tone: the card surface's own, a little denser, so a bar reads on a card and on the window
    static func tone(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 1, opacity: 0.11) : Color.black.opacity(0.075)
    }

    /// the sweep's highlight
    static func highlight(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 1, opacity: 0.13) : Color.white.opacity(0.6)
    }

    /// the widths a title line takes, one per row, so a list of skeletons doesn't look stamped
    static let titleFractions: [CGFloat] = [0.78, 0.62, 0.9, 0.7, 0.55, 0.84, 0.66, 0.74]
    /// the widths of a second line
    static let detailFractions: [CGFloat] = [0.42, 0.55, 0.36, 0.48, 0.6, 0.4, 0.5, 0.34]
}

private struct SkeletonMaskKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SkeletonShimmeringKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// whether a shimmer already sweeps over this view, so a group inside it adds none
    fileprivate var skeletonIsShimmering: Bool {
        get { self[SkeletonShimmeringKey.self] }
        set { self[SkeletonShimmeringKey.self] = newValue }
    }

    /// whether the skeleton is drawn as the shimmer's mask: opaque, so the highlight shows where a bar is
    fileprivate var skeletonIsMask: Bool {
        get { self[SkeletonMaskKey.self] }
        set { self[SkeletonMaskKey.self] = newValue }
    }
}

/// A rounded bar standing in for a line of text, a chip or a picture. Without a `width` or a `fraction` it takes the
/// width it is given; `lineHeight` is the room of the line it stands in for, with the bar centered in it, so a skeleton
/// line is as tall as the text line it replaces.
struct SkeletonBlock: View {
    /// a fixed width, in points
    var width: CGFloat?
    /// the share of the available width, when there is no fixed one
    var fraction: CGFloat?
    var height: CGFloat = 10
    /// the height of the line the bar stands in for; the bar's own height when `nil`
    var lineHeight: CGFloat?
    /// a circle of `height` instead of a bar, for an avatar or a state symbol
    var isCircle = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.skeletonIsMask) private var isMask

    var body: some View {
        if let fraction, width == nil, !isCircle {
            GeometryReader { proxy in
                bar.frame(width: proxy.size.width * fraction, height: height)
                    .frame(maxHeight: .infinity)
            }
            .frame(height: lineHeight ?? height)
        } else if isCircle {
            Circle().fill(fill)
                .frame(width: height, height: height)
                .frame(height: lineHeight ?? height)
        } else {
            bar
                .frame(width: width, height: height)
                .frame(height: lineHeight ?? height)
        }
    }

    private var bar: some View {
        RoundedRectangle(cornerRadius: min(height / 2, 5), style: .continuous)
            .fill(fill)
    }

    private var fill: Color {
        isMask ? .black : Skeleton.tone(scheme)
    }
}

/// `count` lines of text as bars, the last one shorter, like a paragraph.
struct SkeletonLines: View {
    var count = 3
    /// the share of the width the last line takes
    var lastFraction: CGFloat = 0.6
    /// the room of one line, about the height of body text with its spacing
    var lineHeight: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<max(count, 1), id: \.self) { index in
                SkeletonBlock(
                    fraction: index == count - 1 && count > 1 ? lastFraction : 1, height: 10, lineHeight: lineHeight)
            }
        }
        .skeletonShimmer()
    }
}

/// A card that is still loading, with the real card's title and symbol on the real ``DetailCard`` chrome, so it looks
/// like the card it becomes and takes about its room.
struct SkeletonCard: View {
    let title: String
    var symbol: String?
    var lines = 3
    var width: DetailCardWidth = .compact

    var body: some View {
        DetailCard(title, symbol: symbol, width: width) {
            SkeletonLines(count: lines)
        }
    }
}

/// How a skeleton row starts.
enum SkeletonLeading {
    /// no symbol column
    case none
    /// a small state symbol, in a column of the given width
    case symbol(column: CGFloat)
    /// a rounded square, like a workspace's icon
    case square(side: CGFloat)
}

/// One row of a list as bars: an optional symbol, a title line and a second line, in the real rows' size.
struct SkeletonRow: View {
    var index = 0
    var leading = SkeletonLeading.symbol(column: 16)
    /// the lines: a title and one or more under it
    var lines = 2
    var spacing: CGFloat = 6
    /// the room of a title line and of the lines under it
    var titleLine: CGFloat = 16
    var detailLine: CGFloat = 14

    @Environment(\.colorScheme) private var scheme
    @Environment(\.skeletonIsMask) private var isMask

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            switch leading {
            case .none:
                EmptyView()
            case .symbol(let column):
                SkeletonBlock(height: 10, lineHeight: titleLine, isCircle: true)
                    .frame(width: column)
            case .square(let side):
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isMask ? Color.black : Skeleton.tone(scheme))
                    .frame(width: side, height: side)
            }
            VStack(alignment: .leading, spacing: 2) {
                SkeletonBlock(
                    fraction: Skeleton.titleFractions[index % Skeleton.titleFractions.count], height: 10, lineHeight: titleLine)
                if lines > 1 {
                    ForEach(1..<lines, id: \.self) { line in
                        SkeletonBlock(
                            fraction: Skeleton.detailFractions[(index + line) % Skeleton.detailFractions.count], height: 8,
                            lineHeight: detailLine)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .skeletonShimmer()
    }
}

/// `count` rows of a list that is loading, in a `List` or a stack: the real rows' shape, not selectable.
struct SkeletonRows: View {
    var count = 7
    var leading = SkeletonLeading.symbol(column: 16)
    var lines = 2
    var spacing: CGFloat = 6
    var titleLine: CGFloat = 16
    var detailLine: CGFloat = 14

    var body: some View {
        ForEach(0..<count, id: \.self) { index in
            SkeletonRow(
                index: index, leading: leading, lines: lines, spacing: spacing, titleLine: titleLine, detailLine: detailLine
            )
            .selectionDisabled()
        }
    }
}

/// The header of a detail page that is still loading, for the parts the app doesn't know yet: a state badge, a title of
/// two lines, a byline. Whatever is known goes in as real views around it, so a known title replaces the bars.
struct SkeletonHeader: View {
    /// a known reference or title, shown instead of its bar
    var reference: String?
    var title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SkeletonBlock(width: 78, height: 22)
                    .skeletonShimmer(announces: false)
                if let reference {
                    Text(verbatim: reference)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    SkeletonBlock(width: 130, height: 10, lineHeight: 18)
                        .skeletonShimmer(announces: false)
                }
            }
            if let title {
                Text(verbatim: title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    SkeletonBlock(fraction: 0.8, height: 14, lineHeight: 26)
                    SkeletonBlock(fraction: 0.45, height: 14, lineHeight: 26)
                }
                .skeletonShimmer(announces: false)
            }
            HStack(spacing: 6) {
                SkeletonBlock(height: 18, isCircle: true)
                SkeletonBlock(width: 190, height: 9, lineHeight: 16)
            }
            .skeletonShimmer(announces: false)
            HStack(spacing: 6) {
                SkeletonBlock(width: 96, height: 24)
                SkeletonBlock(width: 84, height: 24)
                SkeletonBlock(width: 110, height: 24)
            }
            .skeletonShimmer(announces: false)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Shimmer

extension View {
    /// Sweeps a soft highlight across the skeleton bars in this view, about every 1.2 s; the bars stay still under
    /// Reduce Motion. The sweep follows the clock, so every skeleton on screen moves together. Apply it once to a group
    /// of bars, not to each bar.
    func skeletonShimmer(announces: Bool = true) -> some View {
        modifier(SkeletonShimmer(announces: announces))
    }
}

private struct SkeletonShimmer: ViewModifier {
    /// whether VoiceOver reads the bars as "Loading"; off for a part of a page that also has real text
    var announces: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.skeletonIsShimmering) private var isNested

    @ViewBuilder
    func body(content: Content) -> some View {
        if isNested {
            // A group inside a group: the outer sweep covers it.
            content
        } else {
            content
                .environment(\.skeletonIsShimmering, true)
                .overlay {
                    if !reduceMotion {
                        TimelineView(.animation) { context in
                            let phase = context.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: Skeleton.cycle) / Skeleton.cycle
                            GeometryReader { proxy in
                                let band = max(80, proxy.size.width * 0.4)
                                LinearGradient(
                                    colors: [.clear, Skeleton.highlight(scheme), .clear], startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: band)
                                .offset(x: -band + CGFloat(phase) * (proxy.size.width + band))
                            }
                        }
                        // The sweep shows only where a bar is.
                        .mask {
                            content
                                .environment(\.skeletonIsShimmering, true)
                                .environment(\.skeletonIsMask, true)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading")
                .accessibilityHidden(!announces)
        }
    }
}
