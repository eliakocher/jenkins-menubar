import MenubarCore
import SwiftUI

/// The colours of the update, shared by the Inbox's hero card and the small gift on the Inbox rows of the sidebar and the
/// pane: blue, indigo, purple, pink.
enum WhatsNewStyle {
    static let blue = Color(red: 0.20, green: 0.48, blue: 1.00)
    static let indigo = Color(red: 0.36, green: 0.30, blue: 0.92)
    static let purple = Color(red: 0.62, green: 0.28, blue: 0.90)
    static let pink = Color(red: 0.93, green: 0.30, blue: 0.62)

    /// the four stops, in the order the gradient runs
    static let stops: [Color] = [blue, indigo, purple, pink]

    /// the gradient of the small badge
    static let gradient = LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Returns the colour at a place of the gradient.
    ///
    /// - Parameter position: 0 for blue, 1 for pink; clamped
    static func color(at position: Double) -> Color {
        let clamped = min(max(position, 0), 1) * Double(stops.count - 1)
        let index = min(Int(clamped), stops.count - 2)
        let fraction = clamped - Double(index)
        return stops[index].mix(with: stops[index + 1], by: fraction)
    }
}

/// The small gift on an Inbox row while the update's "What's New" waits: the hero's gradient behind a white gift. It rings
/// white on a highlighted row, whose accent fill would swallow it.
struct WhatsNewGiftBadge: View {
    /// whether the row around it is highlighted or selected
    var isHighlighted = false

    var body: some View {
        Image(systemName: "gift.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 16)
            .background(WhatsNewStyle.gradient, in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white, lineWidth: isHighlighted ? 1.25 : 0)
            }
            .accessibilityLabel("What's New")
            .help("The update's What's New is waiting")
    }
}

/// The moving gradient behind the hero card: a mesh whose points and colours drift in a loop of ``period`` seconds, with a
/// soft glow that wanders across it. With Reduce Motion it stands still at a fixed moment.
struct WhatsNewBackground: View {
    /// how long one loop takes
    static let period: Double = 9
    /// the moment a still frame shows: Reduce Motion's, and the gallery's
    static let stillPhase: Double = 0.8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
            let phase = reduceMotion ? Self.stillPhase : context.date.timeIntervalSinceReferenceDate / Self.period * 2 * .pi
            ZStack {
                Self.mesh(phase: phase)
                glow(phase: phase)
            }
        }
    }

    /// A 3 × 3 mesh: the corners stay, the other points and the colours' places move by a sine each, so the loop closes.
    static func mesh(phase: Double) -> some View {
        func wobble(_ index: Double, _ amount: Double, _ shift: Double = 0) -> Float {
            Float(amount * sin(phase + index * 1.3 + shift))
        }
        let points: [SIMD2<Float>] = [
            [0, 0], [0.5 + wobble(1, 0.12), 0], [1, 0],
            [0, 0.5 + wobble(2, 0.16)], [0.5 + wobble(3, 0.18), 0.5 + wobble(4, 0.20)], [1, 0.5 + wobble(5, 0.16)],
            [0, 1], [0.5 + wobble(6, 0.12), 1], [1, 1],
        ]
        let colors: [Color] = (0..<9).map { node in
            let column = Double(node % 3)
            let row = Double(node / 3)
            let base = (column + row) / 4
            return WhatsNewStyle.color(at: base + 0.16 * sin(phase + Double(node) * 0.9))
        }
        return MeshGradient(width: 3, height: 3, points: points, colors: colors)
    }

    /// a pale glow that wanders across the card: a round gradient that fades out inside its own frame (so it has no edge),
    /// stretched wide
    private func glow(phase: Double) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            RadialGradient(
                colors: [.white.opacity(0.30), .white.opacity(0)], center: .center, startRadius: 0, endRadius: size.height * 0.5
            )
            .frame(width: size.height, height: size.height)
            .scaleEffect(x: 2.6, y: 1.3)
            .position(x: size.width * (0.5 + 0.32 * cos(phase)), y: size.height * (0.5 + 0.2 * sin(phase * 1.3)))
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}

/// The card on top of the Inbox while the update's "What's New" is unread: the moving gradient, a gift that bounces once, the
/// title, the first changes, a "See What's New" button and a ✕ that marks it done. It is self-coloured, so it looks the same
/// in light and dark.
struct InboxWhatsNewHero: View {
    let hero: InboxListModel.Hero
    let open: () -> Void
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var bounce = false
    @ViewState private var isOverClose = false

    static let cornerRadius: CGFloat = 14

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                gift
                texts
                Spacer(minLength: 12)
                seeButton
            }
            HStack(alignment: .top, spacing: 16) {
                gift
                VStack(alignment: .leading, spacing: 14) {
                    texts
                    seeButton
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 40)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.clear)
                .overlay { WhatsNewBackground() }
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
        }
        .overlay(alignment: .topTrailing) { closeButton }
        .shadow(color: WhatsNewStyle.purple.opacity(0.28), radius: 7, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .onTapGesture(perform: open)
        .task {
            // After the card has settled in, once.
            guard !reduceMotion else {
                return
            }
            try? await Task.sleep(for: .milliseconds(450))
            bounce = true
        }
        .accessibilityElement(children: .contain)
    }

    /// the big gift on a frosted disc
    private var gift: some View {
        Image(systemName: "gift.fill")
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white)
            .symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value: bounce)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .frame(width: 58, height: 58)
            .background(.white.opacity(0.20), in: Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.75) }
            .accessibilityHidden(true)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: hero.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            ForEach(Array(hero.highlights.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(.white.opacity(0.7))
                        .frame(width: 4, height: 4)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(verbatim: line)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
        .frame(minWidth: 160, alignment: .leading)
        .layoutPriority(1)
    }

    /// the white capsule that opens the sheet
    private var seeButton: some View {
        Button(action: open) {
            Text("See What's New")
                .font(.callout.weight(.semibold))
                .foregroundStyle(WhatsNewStyle.indigo)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// the small × in the corner: Done
    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(isOverClose ? 1 : 0.75))
                .frame(width: 22, height: 22)
                .background(.white.opacity(isOverClose ? 0.28 : 0.14), in: Circle())
                .accessibilityLabel("Dismiss")
        }
        .buttonStyle(.plain)
        .onHover { isOverClose = $0 }
        .help("Dismiss: marks it done")
        .padding(9)
    }
}
