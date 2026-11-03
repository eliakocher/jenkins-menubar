import SwiftUI

/// Whether the Recently Merged section of the Merge Requests list is open (MR-17). It starts folded when the list has
/// open sections, since merged MRs are history; alone it starts open. A click on its header is remembered. A search
/// opens it, so its matches show.
enum RecentlyMergedFold {
    /// the key of the remembered choice in the user defaults
    static let key = "mergeRequests.recentlyMerged"

    /// Returns whether the section is open.
    ///
    /// - Parameters:
    ///   - stored: the remembered choice, "open" or "closed"; anything else follows the default
    ///   - hasOpenSections: whether the list has open merge requests in other sections
    ///   - searching: whether the window's search has text
    static func isExpanded(stored: String, hasOpenSections: Bool, searching: Bool) -> Bool {
        if searching {
            return true
        }
        switch stored {
        case "open": return true
        case "closed": return false
        default: return !hasOpenSections
        }
    }

    /// Returns the choice after a click on the header.
    ///
    /// - Parameters:
    ///   - stored: the remembered choice
    ///   - isExpanded: whether the section is open now
    static func toggled(stored: String, isExpanded: Bool) -> String {
        isExpanded ? "closed" : "open"
    }
}

/// The header of Recently Merged: the title, its count and a chevron, all one button that folds the section.
struct RecentlyMergedHeader: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            // The chevron at the end, so the title starts where the other sections' titles do.
            HStack(spacing: 6) {
                Text(verbatim: title)
                Text(verbatim: String(count))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Fold \(title)" : "Show \(title)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}
