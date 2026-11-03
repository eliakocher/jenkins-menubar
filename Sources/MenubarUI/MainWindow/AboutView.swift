import MenubarCore
import SwiftUI

/// The About window's content (EGG-21): the icon, the name, the version, the credits roll like a film's end credits, the
/// butler's license note and the copyright. With the easter eggs off only the serious parts stay: the author's credit
/// replaces the roll.
///
/// The roll scrolls slowly after the window opens, and stops for good when the reader scrolls, and while the pointer is
/// over it. With Reduce Motion it stays still, and the reader scrolls it.
struct AboutView: View {
    let eggs: Bool
    let icon: NSImage
    let versionLine: String
    /// whether the roll scrolls by itself; the gallery turns it off so a shot is the same every time
    var scrolls = true

    /// The window's size: the roll needs room, the serious About without it doesn't.
    static func size(eggs: Bool) -> CGSize {
        CGSize(width: 420, height: eggs ? 580 : 390)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 104, height: 104)
                    .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
                    .padding(.bottom, 2)
                Text(verbatim: AppIdentity.displayName)
                    .font(.system(size: 30, weight: .bold))
                if !versionLine.isEmpty {
                    Text(verbatim: versionLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
            if eggs {
                AboutCreditsRoll(scrolls: scrolls)
                    .padding(.top, 14)
            } else {
                AboutCreditRow(line: AboutCredits.author)
                    .padding(.horizontal, 24)
                    .padding(.top, 26)
                Spacer(minLength: 20)
            }
            VStack(spacing: 8) {
                Text(verbatim: EggRules.attribution)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: AboutCredits.copyright)
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 36)
            .padding(.bottom, 22)
        }
        .frame(width: Self.size(eggs: eggs).width, height: Self.size(eggs: eggs).height)
        .background(.background)
    }
}

/// The two-column credits: the role right-aligned in secondary text, the name left-aligned in primary, around a center gap.
private struct AboutCreditsRoll: View {
    let scrolls: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var position = ScrollPosition(edge: .top)
    @ViewState private var actualOffset: CGFloat = 0
    @ViewState private var maxOffset: CGFloat = 0
    @ViewState private var isHovered = false
    @ViewState private var readerTookOver = false

    /// points per second
    private static let speed: CGFloat = 22

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(Array(AboutCredits.groups(eggs: true).enumerated()), id: \.offset) { _, group in
                    VStack(spacing: 4) {
                        ForEach(Array(group.enumerated()), id: \.offset) { _, line in
                            AboutCreditRow(line: line)
                        }
                    }
                }
                Text(verbatim: AboutCredits.closingLine)
                    .font(.system(size: 11).italic())
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($position)
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
            actualOffset = offset
        }
        .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentSize.height - $0.containerSize.height) } action: { _, limit in
            maxOffset = limit
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting || phase == .decelerating {
                readerTookOver = true
            }
        }
        .onHover { isHovered = $0 }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0), .init(color: .black, location: 0.07),
                    .init(color: .black, location: 0.86), .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
        )
        .task {
            guard scrolls, !reduceMotion else {
                return
            }
            try? await Task.sleep(for: .seconds(1.6))
            var offset: CGFloat = 0
            var last = ContinuousClock.now
            while !Task.isCancelled, !readerTookOver {
                try? await Task.sleep(for: .milliseconds(33))
                let now = ContinuousClock.now
                let seconds = last.duration(to: now).seconds
                last = now
                guard !isHovered else {
                    offset = actualOffset
                    continue
                }
                guard offset < maxOffset else {
                    continue
                }
                offset = min(maxOffset, offset + Self.speed * seconds)
                position.scrollTo(y: offset)
            }
        }
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

struct AboutCreditRow: View {
    let line: CreditLine
    private static let gap: CGFloat = 14

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.gap) {
            Text(verbatim: line.role)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(verbatim: line.name)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
    }
}
