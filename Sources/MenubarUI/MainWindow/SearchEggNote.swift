import SwiftUI

extension View {
    /// Shows an easter egg's note above the list while the search text matches (`docs/easter-eggs.md`, Panel): one
    /// quiet line in the secondary style, above whatever the search found, so a real result is never hidden.
    ///
    /// - Parameter note: the note; `nil` shows nothing
    func searchEggNote(_ note: String?) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if let note {
                Text(verbatim: note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
    }
}
