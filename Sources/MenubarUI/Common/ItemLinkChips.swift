import MenubarCore
import SwiftUI

/// What an item link chip does: the same three in every detail header, so a work item, a merge request and a build lead
/// to one another alike (the user, 2026-10-30).
struct ItemLinkActions {
    /// shows the item in the app: its list's selection or "Opened"; the browser while ⌥ is held
    var follow: @MainActor (URL) -> Void
    /// opens the page in the real browser, for "Open in GitLab" and "Open in Jenkins"
    var open: @MainActor (URL) -> Void
    var copy: @MainActor (URL) -> Void
}

extension GitLabSectionActions {
    @MainActor
    var itemLinks: ItemLinkActions {
        ItemLinkActions(follow: { follow($0) }, open: open, copy: copy)
    }
}

extension PanelActions {
    @MainActor
    var itemLinks: ItemLinkActions {
        ItemLinkActions(follow: { follow($0) }, open: open, copy: copy)
    }
}

/// One chip that leads to an item: a click shows it in the app, ⌥ opens it in the browser, and the context menu offers
/// "Show …", "Open in GitLab" or "Open in Jenkins", and "Copy Link".
struct ItemLinkChip: View {
    var symbol: String
    var tint: Color = .secondary
    var text: String
    /// the tooltip: what a click does, and the item's title
    var help: String
    /// "Show Merge Request !12"
    var showTitle: String
    /// "Open in GitLab", "Open Build in Jenkins"
    var openTitle: String
    /// the item's page; `nil` shows a chip that does nothing
    var url: URL?
    let actions: ItemLinkActions

    var body: some View {
        DetailChip(symbol: symbol, tint: tint, text: text, help: help, action: url.map { url in { actions.follow(url) } })
            .contextMenu {
                if let url {
                    ItemLinkMenuItems(showTitle: showTitle, openTitle: openTitle, url: url, actions: actions)
                }
            }
    }
}

/// "Show …", "Open in …" and "Copy Link": the menu of every link to an item.
struct ItemLinkMenuItems: View {
    let showTitle: String
    let openTitle: String
    let url: URL
    let actions: ItemLinkActions

    var body: some View {
        Button(showTitle) { actions.follow(url) }
        Button(openTitle) { actions.open(url) }
        Divider()
        Button("Copy Link") { actions.copy(url) }
    }
}

/// The merge request of a build: "!12477", which shows it in the app.
struct MergeRequestLinkChip: View {
    let mergeRequest: LinkedMergeRequest
    let actions: ItemLinkActions

    var body: some View {
        let short = mergeRequest.shortReference(project: mergeRequest.project)
        ItemLinkChip(
            symbol: "arrow.triangle.pull", text: short,
            help: ["Show Merge Request \(short)", mergeRequest.title].compactMap { $0 }.joined(separator: " · "),
            showTitle: "Show Merge Request \(short)", openTitle: "Open in GitLab", url: mergeRequest.webURL, actions: actions)
    }
}

/// The work items of a merge request or a build: one chip, "Work Item #19202" in a merge request's header and "#19202" in a
/// build's, with the title on hover. Several make "#19202 + 1", whose click lists them.
struct WorkItemLinkChips: View {
    let items: [LinkedWorkItem]
    /// the project whose work items show as "#123"
    let project: String
    /// whether the chip says "Work Item" before the number
    var named = true
    let actions: ItemLinkActions

    @ViewState private var isListing = false

    var body: some View {
        if let first = items.first {
            if items.count == 1 {
                let short = first.shortReference(project: project)
                ItemLinkChip(
                    symbol: "checklist", text: named ? "Work Item \(short)" : short, help: Self.help(first, project: project),
                    showTitle: "Show Work Item \(short)", openTitle: "Open in GitLab", url: first.webURL, actions: actions)
            } else {
                DetailChip(
                    symbol: "checklist", text: "\(first.shortReference(project: project)) + \(items.count - 1)",
                    help: "Show the work items", action: { isListing = true }
                )
                .popover(isPresented: $isListing, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in
                            WorkItemListRow(item: item, project: project, actions: actions) { isListing = false }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: 420)
                }
            }
        }
    }

    /// "Show Work Item #19202 · Dialog bot answers twice"
    static func help(_ item: LinkedWorkItem, project: String) -> String {
        let short = item.shortReference(project: project)
        return ["Show Work Item \(short)", item.title].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A work item in the list of several: "#19202 Title", a click shows it, the context menu has the rest.
private struct WorkItemListRow: View {
    let item: LinkedWorkItem
    let project: String
    let actions: ItemLinkActions
    let done: () -> Void

    @ViewState private var isHovered = false

    var body: some View {
        let short = item.shortReference(project: project)
        Button {
            if let url = item.webURL {
                actions.follow(url)
            }
            done()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checklist")
                    .foregroundStyle(.secondary)
                Text(verbatim: short)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(verbatim: item.title ?? "")
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.fill.quaternary.opacity(isHovered ? 1 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(item.webURL == nil)
        .onHover { isHovered = $0 }
        .help(WorkItemLinkChips.help(item, project: project))
        .contextMenu {
            if let url = item.webURL {
                ItemLinkMenuItems(showTitle: "Show Work Item \(short)", openTitle: "Open in GitLab", url: url, actions: actions)
            }
        }
    }
}
