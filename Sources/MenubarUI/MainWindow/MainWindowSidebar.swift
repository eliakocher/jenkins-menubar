import AppKit
import MenubarCore
import SwiftUI

/// What the sidebar's "Opened" group shows and does (WIN-06): the merge requests and work items opened outside the lists,
/// the selected one, and the actions of its rows.
struct OpenedSidebar {
    var items: [OpenedItem] = []
    var selection: Binding<OpenedItem.ID?> = .constant(nil)
    var actions = OpenedItemActions.none

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

/// The main window's sidebar: the four sections in one group, in the order of ⌘1 to ⌘4, each with its count and, while
/// it has a problem of its own, the red marker (`docs/design/main-window.md`, "Sidebar"; WIN-01). Under them the "Opened"
/// group, while it has items (WIN-06).
struct MainWindowSidebar: View {
    @Binding var section: MainWindowSection
    /// each section's count; a section without one shows no badge
    var badges: [MainWindowSection: Int] = [:]
    /// the marker's tooltip of each section with a problem of its own
    var markers: [MainWindowSection: String] = [:]
    var opened = OpenedSidebar()

    /// What the list selects: a section, or an opened item.
    private enum Choice: Hashable {
        case section(MainWindowSection)
        case opened(OpenedItem.ID)
    }

    var body: some View {
        List(selection: selection) {
            ForEach(MainWindowSection.allCases, id: \.self) { section in
                Label {
                    HStack(spacing: 4) {
                        Text(section.title)
                        if let help = markers[section] {
                            Image(systemName: Marker.problem)
                                .foregroundStyle(.red)
                                .help(help)
                        }
                    }
                } icon: {
                    Image(systemName: section.systemImage)
                }
                .badge(badges[section].map { Text(verbatim: String($0)) })
                .tag(Choice.section(section))
            }
            if !opened.items.isEmpty {
                Section {
                    ForEach(opened.items) { item in
                        OpenedItemRow(item: item, actions: opened.actions)
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
    private var selection: Binding<Choice?> {
        Binding(
            get: { opened.selected.map { .opened($0.id) } ?? .section(section) },
            set: { newValue in
                switch newValue {
                case .section(let chosen)?:
                    opened.selection.wrappedValue = nil
                    section = chosen
                case .opened(let id)?:
                    opened.selection.wrappedValue = id
                case nil:
                    break
                }
            })
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

/// One opened item: its kind's symbol, `!12` or `#12` (a build's number too) and the title, a pin when it is kept, and a ✕ while the pointer is on
/// the row.
private struct OpenedItemRow: View {
    let item: OpenedItem
    let actions: OpenedItemActions

    @ViewState private var isHovered = false

    /// the section whose symbol the item wears
    private static func section(of item: OpenedItem) -> MainWindowSection {
        switch item.kind {
        case .mergeRequest: .mergeRequests
        case .workItem: .workItems
        case .build: .pipelines
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Self.section(of: item).systemImage)
                .foregroundStyle(.secondary)
            Text(verbatim: item.shortReference)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(verbatim: item.title ?? item.fallbackTitle)
                .lineLimit(1)
                .truncationMode(.tail)
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
                .help("Close (⌘W)")
            } else if item.isPinned {
                Image(systemName: "pin.fill")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
        }
        .onHover { isHovered = $0 }
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
