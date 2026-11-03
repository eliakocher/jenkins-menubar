import AppKit
import Observation
import SwiftUI
import Testing

@testable import MenubarUI

@Suite("CardColumnsLayout")
@MainActor
struct CardColumnsLayoutTests {
    @Test(
        "WIN-02 detail cards go in two columns when wide, in one when narrow, and follow a card that grows after loading",
        arguments: [(width: 800.0, columns: 2), (width: 500, columns: 1)])
    func columns(width: Double, columns: Int) {
        let card = GrowingCard()
        let host = NSHostingView(rootView: Self.page(card).frame(width: width))
        let short = host.fittingSize.height
        // Two columns: the taller compact card, 80; one: both with the gap, 40 + 22 + 80; then the gap and the full-width
        // card, 22 + 30.
        #expect(short == (columns == 2 ? 132 : 194))

        // The same cards, one of them taller now: the measured arrangement isn't kept for it.
        card.isTall = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let tall = host.fittingSize.height
        #expect(tall == (columns == 2 ? 252 : 354))
    }

    private static func page(_ card: GrowingCard) -> some View {
        CardColumnsLayout {
            GrowingCardView(card: card)
            Color.blue.frame(height: 80)
            Color.green.frame(height: 30)
                .layoutValue(key: DetailCardWidthKey.self, value: .fullWidth)
        }
    }
}

@Observable
@MainActor
private final class GrowingCard {
    var isTall = false
}

private struct GrowingCardView: View {
    let card: GrowingCard

    var body: some View {
        Color.red.frame(height: card.isTall ? 200 : 40)
    }
}
