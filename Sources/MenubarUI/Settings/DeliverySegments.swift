import MenubarCore
import SwiftUI

/// The single-selection button row of Settings → Notifications: Pop-up · Banner · Inbox · Off, each with a small symbol and a
/// tooltip that says what it does. An option that makes no sense for a row is dimmed and can't be picked, not removed, so
/// the columns line up from row to row.
///
/// It is drawn by hand because the system's segmented picker can't dim one segment, and shows either the symbol or the
/// words of a segment, not both.
struct DeliverySegments: View {
    @Binding var selection: InboxDelivery
    /// the options the row can take; the others are dimmed
    var available: [InboxDelivery] = InboxDelivery.pickerOrder
    /// whether the row is a finished build, which also plays a sound with a pop-up or a banner (the tooltips say it)
    var isBuild = false
    /// whether only the symbols show, for a narrow window; the tooltips still name each
    var symbolsOnly = false
    /// what the row is about, for VoiceOver: "My Jenkins Build Failed or Unstable"
    var subject: String

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    /// the height every segment shares
    static let height: CGFloat = 24

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InboxDelivery.pickerOrder, id: \.self) { choice in
                segment(choice)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(subject)
    }

    private func segment(_ choice: InboxDelivery) -> some View {
        let isSelected = selection == choice
        let isAvailable = available.contains(choice)
        return Button {
            selection = choice
        } label: {
            HStack(spacing: 3) {
                Image(systemName: choice.systemImage)
                    .font(.system(size: 11, weight: .medium))
                if !symbolsOnly {
                    Text(verbatim: choice.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, symbolsOnly ? 8 : 7)
            .frame(height: Self.height)
            .frame(minWidth: symbolsOnly ? 28 : nil)
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.white)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.14), radius: 1, y: 0.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isAvailable ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable || !isEnabled)
        .help(choice.explanation(isBuild: isBuild))
        .accessibilityLabel(choice.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
