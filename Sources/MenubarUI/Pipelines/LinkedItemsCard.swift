import MenubarCore
import SwiftUI

/// The build detail's Linked card: the merge request of the build and its work items as compact rows, each leading to
/// its page in the app (a click), or to GitLab (⌥-click, or the context menu).
struct LinkedItemsCard: View {
    let mergeRequest: LinkedMergeRequest
    let workItems: [LinkedWorkItem]
    let actions: ItemLinkActions

    var body: some View {
        let count = 1 + workItems.count
        DetailCard("Linked", symbol: "link") {
            VStack(alignment: .leading, spacing: 2) {
                let short = mergeRequest.shortReference(project: mergeRequest.project)
                LinkedItemRow(
                    symbol: "arrow.triangle.pull", reference: short, title: mergeRequest.title, kind: "Merge Request",
                    url: mergeRequest.webURL, actions: actions)
                ForEach(workItems) { item in
                    LinkedItemRow(
                        symbol: "checklist", reference: item.shortReference(project: mergeRequest.project), title: item.title,
                        kind: "Work Item", url: item.webURL, actions: actions)
                }
            }
        } accessory: {
            if count > 1 {
                CountBadge(text: "\(count)")
            }
        }
    }
}

/// One linked item: its symbol, reference and title; it lights up on hover like the other detail rows.
private struct LinkedItemRow: View {
    let symbol: String
    /// "!12477" or "#19202"
    let reference: String
    let title: String?
    /// "Merge Request" or "Work Item", for the menu and the tooltip
    let kind: String
    let url: URL?
    let actions: ItemLinkActions

    @ViewState private var isHovered = false

    var body: some View {
        Button {
            if let url { actions.follow(url) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(verbatim: reference)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(verbatim: title ?? "")
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(.fill.quaternary.opacity(isHovered ? 1 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .onHover { isHovered = $0 }
        .help(["Show \(kind) \(reference)", title].compactMap { $0 }.joined(separator: " · "))
        .contextMenu {
            if let url {
                ItemLinkMenuItems(showTitle: "Show \(kind) \(reference)", openTitle: "Open in GitLab", url: url, actions: actions)
            }
        }
    }
}
