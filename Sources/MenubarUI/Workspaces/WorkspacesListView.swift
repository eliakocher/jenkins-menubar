import AppKit
import MenubarCore
import SwiftUI

/// What the Workspaces views do outside themselves: the actions on a checkout, links, and Settings.
struct WorkspaceActions {
    var openInIDE: @MainActor (Checkout) -> Void
    var openInTerminal: @MainActor (Checkout) -> Void
    var revealInFinder: @MainActor (Checkout) -> Void
    /// opens a page in the real browser
    var open: @MainActor (URL) -> Void
    /// shows a work item or merge request in the app, under "Opened" when it isn't in a list; ⌥ held opens the browser
    var follow: @MainActor (URL) -> Void = { _ in }
    var copy: @MainActor (String) -> Void
    var showInPipelines: @MainActor (String) -> Void
    var showInMergeRequests: @MainActor (MergeRequest.ID) -> Void
    /// starts work in a free checkout on a branch, after the detail's confirmation (WS-08)
    var startWork: @MainActor (Checkout, String) -> Void
    /// opens Settings → Repositories
    var openSettings: @MainActor () -> Void

    /// Actions that do nothing, for the gallery.
    static let none = WorkspaceActions(
        openInIDE: { _ in }, openInTerminal: { _ in }, revealInFinder: { _ in }, open: { _ in }, copy: { _ in },
        showInPipelines: { _ in }, showInMergeRequests: { _ in }, startWork: { _, _ in }, openSettings: {})

    /// The window's actions.
    @MainActor
    static func live(model: AppModel, router: WindowRouter, openURL: OpenURLAction) -> WorkspaceActions {
        let store = model.workspaces
        return WorkspaceActions(
            openInIDE: { checkout in Task { await store.openInIDE(checkout) } },
            openInTerminal: { checkout in Task { await store.openInTerminal(checkout) } },
            revealInFinder: { checkout in Task { await store.revealInFinder(checkout) } },
            open: { router.browse($0, fallback: openURL) },
            follow: { router.follow($0, model: model, fallback: openURL) },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            showInPipelines: { router.showInPipelines(job: $0) },
            showInMergeRequests: { router.showInMergeRequests($0) },
            startWork: { checkout, branch in Task { await store.startWork(in: checkout, branch: branch) } },
            openSettings: { router.open(.settings(pane: .repositories)) })
    }
}

/// The Workspaces section's content column (WS-01 to WS-04): one row per checkout of Settings → Repositories, with
/// what it works on and where its git state stands, filtered by the window's search.
///
/// It reads the stores from the environment; while it shows, the store reads the checkouts with git, then every few
/// minutes (WS-02).
public struct WorkspacesListView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    @Binding private var selection: Checkout.ID?
    private let searchText: String

    /// the name the section shows the checkouts under
    static let host = "workspaces-section"

    /// - Parameters:
    ///   - selection: the selected checkout, by its path
    ///   - searchText: the window's search text; empty shows everything
    public init(selection: Binding<Checkout.ID?>, searchText: String) {
        _selection = selection
        self.searchText = searchText
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            WorkspacesListContent(
                model: WorkspacesListModel(WorkspacesData(model, now: context.date), query: searchText),
                selection: $selection,
                actions: .live(model: model, router: router, openURL: openURL))
        }
        .onAppear {
            model.workspaces.show(by: Self.host)
        }
        .onDisappear {
            model.workspaces.hide(by: Self.host)
        }
    }
}

/// The Workspaces list drawn from plain values, for the window and the gallery.
struct WorkspacesListContent: View {
    let model: WorkspacesListModel
    @Binding var selection: Checkout.ID?
    let actions: WorkspaceActions

    var body: some View {
        List(selection: $selection) {
            if model.isPlaceholder {
                WorkspacePlaceholderRows()
            }
            ForEach(model.rows) { row in
                WorkspaceRowContent(row: row)
                    .tag(row.id)
            }
            if !model.folderProblems.isEmpty, model.empty == nil {
                Section {
                    ForEach(model.folderProblems, id: \.self) { problem in
                        Label {
                            Text(verbatim: problem)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } icon: {
                            Image(systemName: Marker.problem)
                                .foregroundStyle(.red)
                        }
                        .font(.subheadline)
                        .selectionDisabled()
                    }
                    Button("Repositories Settings…") { actions.openSettings() }
                        .buttonStyle(.link)
                        .font(.subheadline)
                        .selectionDisabled()
                }
            }
        }
        .contextMenu(forSelectionType: Checkout.ID.self) { ids in
            if let row = model.row(ids.first) {
                WorkspaceMenuItems(row: row, hasIDECommand: model.hasIDECommand, actions: actions)
            }
        } primaryAction: { ids in
            if let row = model.row(ids.first) {
                primary(row)
            }
        }
        .onKeyPress(.return) {
            guard let row = model.row(selection) else {
                return .ignored
            }
            primary(row)
            return .handled
        }
        .overlay {
            switch model.empty {
            case .noFolders:
                ContentUnavailableView {
                    Label("No Repositories", systemImage: MainWindowSection.workspaces.systemImage)
                } description: {
                    Text(
                        "Add the folders of your git checkouts in Settings: one checkout, or a pattern like "
                            + "~/workspaces/*/project for several clones side by side.")
                } actions: {
                    Button("Repositories Settings…") { actions.openSettings() }
                }
            case .noCheckouts:
                ContentUnavailableView {
                    Label("No Checkouts Found", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(verbatim: model.folderProblems.first ?? "None of the folders has a git checkout.")
                } actions: {
                    Button("Repositories Settings…") { actions.openSettings() }
                }
            case nil:
                if model.findsNothing {
                    ContentUnavailableView.search(text: model.query)
                }
            }
        }
    }

    /// Return and a double click open the IDE, or Finder without an IDE command.
    private func primary(_ row: WorkspaceRowModel) {
        if model.hasIDECommand {
            actions.openInIDE(row.checkout)
        } else {
            actions.revealInFinder(row.checkout)
        }
    }
}

/// The context menu of a checkout's row.
struct WorkspaceMenuItems: View {
    let row: WorkspaceRowModel
    let hasIDECommand: Bool
    let actions: WorkspaceActions

    var body: some View {
        Button("Open in IDE") { actions.openInIDE(row.checkout) }
            .disabled(!hasIDECommand)
        Button("Open in Terminal") { actions.openInTerminal(row.checkout) }
        Button("Reveal in Finder") { actions.revealInFinder(row.checkout) }
        Divider()
        if let mergeRequest = row.task.mergeRequest {
            Button("Show Merge Request \(row.mergeRequestReference ?? "")") { actions.follow(mergeRequest.webURL) }
        }
        if let url = row.task.workItemURL {
            Button("Show Work Item \(row.number ?? "")") { actions.follow(url) }
        }
        Divider()
        Button("Copy Path") { actions.copy(row.checkout.path) }
        if let branch = row.branch {
            Button("Copy Branch Name") { actions.copy(branch) }
        }
    }
}

/// A checkout's state as a small rounded tile with a white glyph: green and a check when free, blue and a branch while
/// a task runs in it, orange and a pencil with changed files, red when git can't read it.
struct WorkspaceTile: View {
    let kind: WorkspaceRowModel.Kind
    var size: CGFloat = 28

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Image(systemName: Self.symbol(of: kind))
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.tint(of: kind).gradient, in: shape)
            .overlay { shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
            .shadow(color: Self.tint(of: kind).opacity(0.25), radius: 2, y: 1)
            .accessibilityHidden(true)
    }

    static func symbol(of kind: WorkspaceRowModel.Kind) -> String {
        switch kind {
        case .free: "checkmark"
        case .working: "arrow.triangle.branch"
        case .changed: "pencil"
        case .detached: "pin"
        case .problem: "exclamationmark"
        case .unknown: "ellipsis"
        }
    }

    static func tint(of kind: WorkspaceRowModel.Kind) -> Color {
        switch kind {
        case .free: .green
        case .working: .blue
        case .changed: .orange
        case .detached: .gray
        case .problem: .red
        case .unknown: Color(nsColor: .tertiaryLabelColor)
        }
    }
}

/// A checkout's row (WS-01): the tile, the folder's name with "Free" or the changed files, the task (the work item's
/// number and title instead of the long branch name), and a line of facts: the merge request, its Jenkins build, ahead
/// and behind `origin/<base>`, and a quiet warning when the local base lags far behind.
struct WorkspaceRowContent: View {
    let row: WorkspaceRowModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            WorkspaceTile(kind: row.kind)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: row.checkout.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    WorkspaceBadge(row: row)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if let number = row.number, row.branch != row.checkout.baseBranch {
                        Text(verbatim: number)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text(verbatim: row.title)
                        .foregroundStyle(row.kind == .free || row.titleFromBranch ? .secondary : .primary)
                        .lineLimit(1)
                }
                .help(row.branch ?? row.title)
                WorkspaceFacts(row: row)
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 3)
    }
}

/// "Free", "3 changed", or "Can't read", at the row's trailing edge; nothing for a clean task.
struct WorkspaceBadge: View {
    let row: WorkspaceRowModel

    var body: some View {
        switch row.kind {
        case .free:
            StatusBadge(text: "Free", symbol: "checkmark", tint: .green)
                .help("Clean on \(row.checkout.baseBranch): ready for the next task")
        case .changed:
            if let count = row.changedCount {
                StatusBadge(text: "\(count) changed", symbol: "pencil", tint: .orange)
                    .help(row.changes ?? "")
            }
        case .problem:
            StatusBadge(text: "Can't Read", symbol: nil, tint: .red)
                .help(row.problem ?? "")
        case .working, .detached, .unknown:
            EmptyView()
        }
    }
}

/// The row's line of facts, wrapping when narrow: the merge request with its status's symbol, its Jenkins build, ahead
/// and behind, the stale local base.
struct WorkspaceFacts: View {
    let row: WorkspaceRowModel

    var body: some View {
        PillFlowLayout(spacing: 10, lineSpacing: 2) {
            if let status = row.status, let reference = row.mergeRequestReference {
                fact(symbol: status.symbol, color: status.color.swiftUI, text: reference)
                    .help("\(reference) · \(status.text)")
            } else if row.kind != .free, row.branch != nil, row.branch != row.checkout.baseBranch {
                Text("No merge request")
                    .foregroundStyle(.tertiary)
            }
            if let build = row.build, let text = row.buildText {
                fact(symbol: build.symbol, color: build.color, text: text.components(separatedBy: " · ").first ?? text)
                    .help("Jenkins build \(text)")
            }
            if let aheadBehind = row.aheadBehind?.compact {
                Text(verbatim: aheadBehind)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("\(row.aheadBehind?.words ?? "") of origin/\(row.checkout.baseBranch)")
            }
            if row.hasStaleBase, let behind = row.localBaseBehind {
                fact(
                    symbol: "exclamationmark.triangle", color: .yellow,
                    text: "local \(row.checkout.baseBranch) \(behind) behind")
                    .help("The local \(row.checkout.baseBranch) is \(behind) commits behind origin/\(row.checkout.baseBranch)")
            }
            if let problem = row.problem {
                Text(verbatim: problem)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(symbol: String, color: Color?, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol)
                .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .imageScale(.small)
            Text(verbatim: text)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// Rows of bars standing in for checkouts not read yet: the icon, a name, a task's title and the numbers.
private struct WorkspacePlaceholderRows: View {
    var body: some View {
        SkeletonRows(count: 4, leading: .square(side: 28), lines: 3, spacing: 10, titleLine: 18, detailLine: 14)
    }
}
