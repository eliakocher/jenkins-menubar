import AppKit
import MenubarCore
import SwiftUI

/// What the sidebar's "Opened" group shows and does (WIN-06): the merge requests and work items opened outside the lists,
/// the selected one, and the actions of its rows.
struct OpenedSidebar {
    var items: [OpenedItem] = []
    var selection: Binding<OpenedItem.ID?> = .constant(nil)
    var actions = OpenedItemActions.none
    /// what a row shows besides its kind: the title, the symbol's colour and the chips. Called in the row's own body, so
    /// what it reads from the store (as loaded, never fetched) is tracked by that row alone.
    var details: @MainActor (OpenedItem) -> OpenedItemRowDetails = { OpenedItemRowDetails.make(item: $0) }

    /// the selected item, if it is still open
    var selected: OpenedItem? {
        selection.wrappedValue.flatMap { id in items.first { $0.id == id } }
    }
}

/// What the rows of "Opened" do.
struct OpenedItemActions {
    var close: @MainActor (OpenedItem.ID) -> Void
    var closeAll: @MainActor () -> Void
    var setPinned: @MainActor (OpenedItem.ID, Bool) -> Void
    var openInGitLab: @MainActor (URL) -> Void
    var copyLink: @MainActor (URL) -> Void

    /// nothing, for the gallery
    static let none = OpenedItemActions(
        close: { _ in }, closeAll: {}, setPinned: { _, _ in }, openInGitLab: { _ in }, copyLink: { _ in })
}

/// The main window's sidebar: the sections in one group, in the order of ⌘1 and on, each with its count and, while
/// it has a problem of its own, the red marker (`docs/design/main-window.md`, "Sidebar"; WIN-01). Under them the "Opened"
/// group, while it has items (WIN-06).
struct MainWindowSidebar: View {
    @Binding var section: MainWindowSection
    /// the sections it lists, in order; Digest only while the Claude features are on
    var sections = MainWindowSection.allCases
    /// called with the offsets and the destination of a drag of the rows, which saves the new order; `nil` leaves them
    /// fixed
    var moveSections: ((IndexSet, Int) -> Void)?
    /// each section's count; a section without one shows no badge
    var badges: [MainWindowSection: Int] = [:]
    /// the marker's tooltip of each section with a problem of its own
    var markers: [MainWindowSection: String] = [:]
    /// the sections with something new to look at, which get a small accent dot
    var unread: Set<MainWindowSection> = []
    var opened = OpenedSidebar()

    /// What the list selects: a section, or an opened item.
    private enum Choice: Hashable {
        case section(MainWindowSection)
        case opened(OpenedItem.ID)
    }

    var body: some View {
        List(selection: selection) {
            ForEach(sections, id: \.self) { section in
                Label {
                    HStack(spacing: 4) {
                        Text(section.title)
                        if let help = markers[section] {
                            Image(systemName: Marker.problem)
                                .foregroundStyle(.red)
                                .help(help)
                        }
                        if unread.contains(section) {
                            SidebarUnreadDot()
                        }
                    }
                } icon: {
                    Image(systemName: section.systemImage)
                }
                .badge(badges[section].map { Text(verbatim: String($0)) })
                .tag(Choice.section(section))
            }
            // The rows drag into the user's order, like Finder's sidebar; Settings → Appearance lists the same order.
            .onMove(perform: moveSections)
            if !opened.items.isEmpty {
                Section {
                    ForEach(opened.items) { item in
                        OpenedItemRow(item: item, actions: opened.actions, details: opened.details)
                            .tag(Choice.opened(item.id))
                    }
                } header: {
                    OpenedHeader(actions: opened.actions, hasUnpinned: opened.items.contains { !$0.isPinned })
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// The list wants an optional selection; the sidebar always has one, so clearing it keeps the old one.
    ///
    /// A click moves the highlight at once and changes the section a moment later: the new section's list, detail and
    /// toolbar take a while to build, and built in the same update they held the highlight back (the user, 2026-11-02:
    /// "i click and like only 1 second later it gets selected").
    private var selection: Binding<Choice?> {
        Binding(
            get: { clicked ?? opened.selected.map { .opened($0.id) } ?? .section(section) },
            set: { newValue in
                guard let newValue else {
                    return
                }
                clicked = newValue
                Task { @MainActor in
                    // Long enough for the window to draw the highlight first.
                    try? await Task.sleep(for: .milliseconds(1))
                    apply(newValue)
                    if clicked == newValue {
                        clicked = nil
                    }
                }
            })
    }

    /// the row clicked last, until the section or item behind it shows
    @ViewState private var clicked: Choice?

    private func apply(_ choice: Choice) {
        switch choice {
        case .section(let chosen):
            opened.selection.wrappedValue = nil
            section = chosen
        case .opened(let id):
            opened.selection.wrappedValue = id
        }
    }
}

/// The small dot after a sidebar row's title: something new is waiting in the section. The accent color, white on the
/// selected row, whose accent fill would swallow it.
struct SidebarUnreadDot: View {
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        // Red, like an unread badge; on the selected row, whose accent fill would swallow it, it keeps a white ring.
        Circle()
            .fill(MergeRequestStatus.Color.red.swiftUI)
            .overlay {
                Circle().strokeBorder(.white, lineWidth: prominence == .increased ? 1.25 : 0)
            }
            .frame(width: 8, height: 8)
            .accessibilityLabel("New")
            .help("A digest you haven't seen yet")
    }
}

/// The "Opened" group's header, with a menu for Close All.
private struct OpenedHeader: View {
    let actions: OpenedItemActions
    /// whether Close All has something to close: pinned items stay
    let hasUnpinned: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("Opened")
            Spacer(minLength: 0)
            Menu {
                Button("Close All") { actions.closeAll() }
                    .disabled(!hasUnpinned)
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel("Opened Items")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Close all opened items that aren't pinned")
        }
    }
}

/// One opened item in two lines (the user, 2026-11-03: "i almost don't see the title"): its kind's symbol, coloured, then
/// the title without its leading work item number, and below it the small chips of its numbers. A pin when it is kept at
/// the end, and a ✕ while the pointer is on the row.
private struct OpenedItemRow: View {
    let item: OpenedItem
    let actions: OpenedItemActions
    let details: @MainActor (OpenedItem) -> OpenedItemRowDetails

    @ViewState private var isHovered = false
    /// `.increased` on the selected row, whose accent fill would swallow the colours
    @Environment(\.backgroundProminence) private var prominence

    /// the section whose symbol the item wears
    private static func section(of item: OpenedItem) -> MainWindowSection {
        switch item.kind {
        case .mergeRequest: .mergeRequests
        case .workItem: .workItems
        case .build: .pipelines
        }
    }

    var body: some View {
        let details = details(item)
        let isSelected = prominence == .increased
        HStack(spacing: 8) {
            Image(systemName: Self.section(of: item).systemImage)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : details.symbolTint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                // One width for every kind's symbol, so the titles start at the same place.
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: details.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                OpenedItemChipsLine(chips: details.chips)
                    .environment(\.menuHighlighted, isSelected)
            }
            Spacer(minLength: 0)
            if isHovered {
                Button {
                    actions.close(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .accessibilityLabel("Close")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close (⌘W or middle-click)")
            } else if item.isPinned {
                Image(systemName: "pin.fill")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
        }
        .onHover { isHovered = $0 }
        // The same close as the ✕ and the context menu's, whatever the row's pin.
        .onMiddleClick { actions.close(item.id) }
        .help(item.title.map { "\($0)\n\(item.reference)" } ?? item.reference)
        .contextMenu {
            Button("Close") { actions.close(item.id) }
            Button(item.isPinned ? "Unpin" : "Pin") { actions.setPinned(item.id, !item.isPinned) }
            Divider()
            Button(item.kind == .build ? "Open Build in Jenkins" : "Open in GitLab") { actions.openInGitLab(item.webURL) }
            Button("Copy Link") { actions.copyLink(item.webURL) }
        }
    }
}
