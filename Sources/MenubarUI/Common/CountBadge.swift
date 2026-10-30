import SwiftUI

/// A small count in a tinted capsule, for a card's headline: "7 open".
struct CountBadge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(verbatim: text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}
