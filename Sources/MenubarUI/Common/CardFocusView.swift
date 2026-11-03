import MenubarCore
import SwiftUI

// A detail page brings one of its cards into view when a link or an Inbox entry asks (``CardFocus``): it scrolls to the
// card, top anchored and animated, and the card pulses once so the eye finds it. A page does this with two parts: the card
// says it can be a target (``SwiftUICore/View/cardFocusTarget(_:)``), and the page's ScrollView takes the request
// (``SwiftUICore/View/takesCardFocus(_:ids:)``).

private struct PulsingCardKey: EnvironmentKey {
    static let defaultValue: DetailCardID? = nil
}

extension EnvironmentValues {
    /// the card that pulses now, set by ``SwiftUICore/View/takesCardFocus(_:ids:)`` for the cards below it
    var pulsingCard: DetailCardID? {
        get { self[PulsingCardKey.self] }
        set { self[PulsingCardKey.self] = newValue }
    }
}

extension View {
    /// Marks a card as one a page can scroll to: it gets the id the scroll jumps to, and pulses a ring and a veil while
    /// it is the focused card.
    ///
    /// - Parameter card: which card it is
    func cardFocusTarget(_ card: DetailCardID) -> some View {
        modifier(CardFocusTarget(card: card, addsID: true))
    }

    /// Marks a card as one that pulses while it is the focused card, for a page whose scroll ids are its own.
    ///
    /// - Parameter card: which card it is
    func cardFocusPulse(_ card: DetailCardID) -> some View {
        modifier(CardFocusTarget(card: card, addsID: false))
    }

    /// Lets a page take the card request of the window's router: the first time the page shows and whenever one is made, it
    /// scrolls to the card and pulses it. Apply it to the page's `ScrollView`.
    ///
    /// - Parameters:
    ///   - proxy: the page's scroll proxy
    ///   - ids: the ids the page's cards scroll by, where they aren't the card's own
    ///   - enabled: whether the page takes requests; a skeleton, which has no cards yet, leaves them to the page that follows
    func takesCardFocus(_ proxy: ScrollViewProxy, ids: [DetailCardID: AnyHashable] = [:], enabled: Bool = true) -> some View {
        modifier(CardFocusTaker(proxy: proxy, ids: ids, enabled: enabled))
    }
}

private struct CardFocusTarget: ViewModifier {
    let card: DetailCardID
    let addsID: Bool

    @Environment(\.pulsingCard) private var pulsing

    func body(content: Content) -> some View {
        let shown = pulsing == card
        let tint: Color = card == .claude ? .purple : .accentColor
        let shape = RoundedRectangle(cornerRadius: DetailCard<EmptyView, EmptyView>.cornerRadius, style: .continuous)
        let marked = content.overlay {
            shape
                .fill(tint.opacity(shown ? 0.10 : 0))
                .overlay { shape.strokeBorder(tint.opacity(shown ? 0.85 : 0), lineWidth: 2) }
                .allowsHitTesting(false)
        }
        if addsID {
            marked.id(card)
        } else {
            marked
        }
    }
}

private struct CardFocusTaker: ViewModifier {
    let proxy: ScrollViewProxy
    let ids: [DetailCardID: AnyHashable]
    let enabled: Bool

    @Environment(WindowRouter.self) private var router: WindowRouter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var pulsing: DetailCardID?
    @ViewState private var running: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .environment(\.pulsingCard, pulsing)
            .onChange(of: router?.cardFocus.pending, initial: true) { _, pending in
                guard enabled, pending != nil, let card = router?.takeCardFocus() else {
                    return
                }
                focus(card)
            }
            .onDisappear { running?.cancel() }
    }

    /// Scrolls to the card once the page has laid out, again when the cards above it settled (the description arrives
    /// late and moves it), and pulses it in between.
    private func focus(_ card: DetailCardID) {
        running?.cancel()
        let target = ids[card] ?? AnyHashable(card)
        running = Task {
            // The page that was just shown needs a moment to lay out before it can scroll.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            scroll(to: target)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { pulsing = card }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            scroll(to: target)
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.7)) { pulsing = nil }
        }
    }

    private func scroll(to target: AnyHashable) {
        withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(target, anchor: .top) }
    }
}
