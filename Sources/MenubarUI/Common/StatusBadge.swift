import SwiftUI

/// A state as a small tinted capsule, like the state badge of a GitLab issue or merge request: an optional symbol and the
/// state's word in the tint, on a faint fill of it. Plain text, never markup.
struct StatusBadge: View {
    let text: String
    var symbol: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
            }
            Text(verbatim: text)
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay { Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5) }
        .accessibilityElement(children: .combine)
    }
}
