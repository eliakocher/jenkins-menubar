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
    /// the symbol of a chip that isn't a work item or merge request reference; `nil` for a reference
    var symbol: String?
    var tint: Color = .secondary
    /// the text's colour; `nil` keeps the label colour
    var textTint: Color?
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

    /// Returns the chip of a work item or merge request reference: no symbol, the number in the kind's colour, blue "#18874"
    /// and green "!12501" (the user, 2026-11-03).
    init(
        reference kind: ReferenceKind, text: String, help: String, showTitle: String, openTitle: String, url: URL?,
        actions: ItemLinkActions
    ) {
        self.init(
            symbol: nil, tint: kind.tint, textTint: kind.tint, text: text, help: help, showTitle: showTitle, openTitle: openTitle,
            url: url, actions: actions)
    }

    /// Returns the chip of anything else that leads to an item: a build, a slot.
    init(
        symbol: String, tint: Color = .secondary, text: String, help: String, showTitle: String, openTitle: String, url: URL?,
        actions: ItemLinkActions
    ) {
        self.init(
            symbol: Optional(symbol), tint: tint, textTint: nil, text: text, help: help, showTitle: showTitle, openTitle: openTitle,
            url: url, actions: actions)
    }

    private init(
        symbol: String?, tint: Color, textTint: Color?, text: String, help: String, showTitle: String, openTitle: String,
        url: URL?, actions: ItemLinkActions
    ) {
        self.symbol = symbol
        self.tint = tint
        self.textTint = textTint
        self.text = text
        self.help = help
        self.showTitle = showTitle
        self.openTitle = openTitle
        self.url = url
        self.actions = actions
    }

    var body: some View {
        chip
            .contextMenu {
                if let url {
                    ItemLinkMenuItems(showTitle: showTitle, openTitle: openTitle, url: url, actions: actions)
                }
            }
    }

    @ViewBuilder
    private var chip: some View {
        if let url {
            DetailChip(symbol: symbol, tint: tint, help: help, action: { actions.follow(url) }) { label }
        } else {
            DetailChip(symbol: symbol, tint: tint, help: help) { label }
        }
    }

    private var label: some View {
        Text(verbatim: text)
            .monospacedDigit()
            .foregroundStyle(textTint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
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

/// The two kinds of reference, and the look each has everywhere in the app (the user, 2026-11-03: "we say the workitems are
/// a blue chip and always starts with # while MR are always green and start with !"): a work item is a blue chip, "#18874"
/// (an epic "&12"), a merge request a green one, "!12501". No symbol and no word in either: the colour and the first
/// character say what it is. A merge request's chip is green whatever its state; the state is for the tooltip and, where
/// it matters, for a word beside the chip.
enum ReferenceKind: Hashable, Sendable {
    case workItem
    case mergeRequest

    /// blue for a work item, green for a merge request
    var tint: Color {
        switch self {
        case .workItem: .workItemNumber
        case .mergeRequest: MergeRequestStatus.Color.green.swiftUI
        }
    }

    /// Returns the tooltip of a reference: the number, the state where there is one, and the title, "!12404 · merged · Title".
    ///
    /// - Parameters:
    ///   - reference: "!12404", "#18874"
    ///   - state: the state's word, like "merged"; `nil` or empty leaves it out
    ///   - title: the item's title
    static func tooltip(_ reference: String, state: String? = nil, title: String? = nil) -> String {
        [reference, state, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The merge request of a build: "!12477", which shows it in the app.
struct MergeRequestLinkChip: View {
    let mergeRequest: LinkedMergeRequest
    let actions: ItemLinkActions

    var body: some View {
        let short = mergeRequest.shortReference(project: mergeRequest.project)
        ItemLinkChip(
            reference: .mergeRequest, text: short,
            help: ReferenceKind.tooltip("Show Merge Request \(short)", title: mergeRequest.title),
            showTitle: "Show Merge Request \(short)", openTitle: "Open in GitLab", url: mergeRequest.webURL, actions: actions)
    }
}

/// The work items of a merge request or a build: one blue chip, "#19202", with the title on hover. Several make
/// "#19202 + 1", whose click lists them.
struct WorkItemLinkChips: View {
    let items: [LinkedWorkItem]
    /// the project whose work items show as "#123"
    let project: String
    let actions: ItemLinkActions

    @ViewState private var isListing = false

    var body: some View {
        if let first = items.first {
            if items.count == 1 {
                let short = first.shortReference(project: project)
                ItemLinkChip(
                    reference: .workItem, text: short, help: Self.help(first, project: project),
                    showTitle: "Show Work Item \(short)", openTitle: "Open in GitLab", url: first.webURL, actions: actions)
            } else {
                DetailChip(
                    symbol: nil, tint: ReferenceKind.workItem.tint,
                    help: "List the \(items.count) work items to pick one", action: { isListing = true }
                ) {
                    Text(verbatim: "\(first.shortReference(project: project)) + \(items.count - 1)")
                        .monospacedDigit()
                        .foregroundStyle(ReferenceKind.workItem.tint)
                }
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

    /// "Show Work Item #19202 · Dialog bot answers twice", the tooltip of a work item's chip
    static func help(_ item: LinkedWorkItem, project: String) -> String {
        ReferenceKind.tooltip("Show Work Item \(item.shortReference(project: project))", title: item.title)
    }
}

/// A work item in the list of several: its blue chip and the title, a click shows it, the context menu has the rest.
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
                ReferenceChip(kind: .workItem, text: short)
                    .fixedSize()
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

// MARK: - Inline chips of list rows

extension Color {
    /// The grey of a neutral chip (a build's number, the type): the label colour, a little quieter. The secondary style was
    /// too faint on its own fill to read (the user, 2026-11-02: "change a bit the grey, it's not very readable").
    static let chipNeutral = Color.primary.opacity(0.78)

    /// The colour of a work item's reference: blue. No merge request colour uses it (the user, 2026-11-03).
    static let workItemNumber = Color.blue
}

extension View {
    /// Draws a view as the small chip of a list row's line 2: caption text in the tint on a faint fill of it, a capsule that
    /// is no taller than the line's own text. While a menu row is highlighted it draws white on a lighter fill, as the
    /// row's text.
    ///
    /// - Parameter tint: the chip's color
    func inlineChip(tint: Color) -> some View {
        modifier(InlineChipLook(tint: tint))
    }
}

private extension View {
    /// Adds a tooltip when there is one; without, the row's own shows over the chip.
    @ViewBuilder
    func optionalHelp(_ text: String?) -> some View {
        if let text {
            help(text)
        } else {
            self
        }
    }
}

private struct InlineChipLook: ViewModifier {
    let tint: Color
    @Environment(\.menuHighlighted) private var isHighlighted

    func body(content: Content) -> some View {
        content
            .font(.caption)
            .foregroundStyle(isHighlighted ? Color.white : tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(isHighlighted ? Color.white.opacity(0.22) : tint.opacity(0.14), in: Capsule())
    }
}

/// The small chip of a work item or a merge request reference, "#18874" in blue or "!12" in green, in every list row,
/// flyout and card: the one look of the two (``ReferenceKind``). No symbol, no state. It is no button: the row's own click
/// shows the item. The text is cut in the middle when the line is short of room, so its digits stay.
struct ReferenceChip: View {
    let kind: ReferenceKind
    /// "!12", "other!12" for another project, "#18874", "&12" for an epic
    let text: String
    /// a build result's glyph after the number: the pipeline of a merge request, coloured by its result (it is the build's
    /// state, not the merge request's); `nil` for none
    var build: BuildState?
    /// the tooltip; `nil` leaves the row's own
    var help: String?

    var body: some View {
        HStack(spacing: 3) {
            Text(verbatim: text)
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
            if let build {
                Image(systemName: build.symbol)
                    .foregroundStyle(build.color ?? .secondary)
            }
        }
        .inlineChip(tint: kind.tint)
        .optionalHelp(help)
    }
}

/// A merge request's number as the small chip of a list row, "!12": green, whatever the merge request's state (the user,
/// 2026-11-03). See ``ReferenceChip``.
struct MergeRequestNumberChip: View {
    let text: String
    /// the result of the merge request's build, shown as a glyph after the number
    var build: BuildState?
    var help: String?

    var body: some View {
        ReferenceChip(kind: .mergeRequest, text: text, build: build, help: help)
    }
}

/// A work item's number as the small chip of a list row, "#18874": blue. See ``ReferenceChip``.
struct WorkItemNumberChip: View {
    /// "#18874", "&12" for an epic
    let text: String
    var help: String?

    var body: some View {
        ReferenceChip(kind: .workItem, text: text, help: help)
    }
}
