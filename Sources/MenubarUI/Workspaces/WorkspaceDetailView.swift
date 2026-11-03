import MenubarCore
import SwiftUI

/// The Workspaces section's detail column (WS-01 to WS-05): the selected checkout with its actions, what it works on
/// (the work item, the merge request and its Jenkins build, with links) and its git state; blank without a selection.
public struct WorkspaceDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    private let selection: Checkout.ID?

    /// - Parameter selection: the selected checkout, by its path
    public init(selection: Checkout.ID?) {
        self.selection = selection
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let list = WorkspacesListModel(WorkspacesData(model, now: context.date))
            WorkspaceDetailContent(
                row: list.row(selection), home: list.home, hasIDECommand: list.hasIDECommand,
                readAt: model.workspaces.lastRefreshAt, now: context.date, startWorkItems: list.startWorkItems,
                actions: .live(model: model, router: router, openURL: openURL))
        }
        .task(id: BranchesLoad(selection: selection, readAt: model.workspaces.lastRefreshAt)) {
            // The local branches are read when a checkout is selected, and again after each reading of the checkouts.
            if let checkout = model.workspaces.checkouts.first(where: { $0.id == selection }) {
                await model.workspaces.loadBranches(checkout)
            }
        }
    }

    /// what makes the selected checkout's branches be read again
    private struct BranchesLoad: Hashable {
        var selection: Checkout.ID?
        var readAt: Date?
    }
}

/// The detail drawn from plain values, for the window and the gallery: a scrolling page in the merge request detail's
/// language, so it takes the content width like the others. The header has the checkout's name, its state and its path,
/// the ahead and behind chips and the ⋯ menu; the action row under it has every frequent action as a button. Then the
/// cards: Start Work Here for a free checkout, Task (the work item, the merge request and its Jenkins build) and
/// Checkout (branch, changes, ahead and behind, the local base) side by side when wide, and the local branches without a
/// merge request across the width. Skeleton cards while the checkout isn't read.
struct WorkspaceDetailContent: View {
    let row: WorkspaceRowModel?
    let home: URL
    let hasIDECommand: Bool
    /// when git last read the checkouts
    let readAt: Date?
    let now: Date
    /// the open work items the app knows, for Start Work Here
    var startWorkItems: [StartWorkItem] = []
    let actions: WorkspaceActions

    var body: some View {
        if let row {
            DetailPage(id: row.id) { _ in
                header(row)
                CardColumnsLayout {
                    if row.kind == .free {
                        StartWorkSection(
                            checkout: row.checkout, items: startWorkItems, isRunning: row.isStartingWork,
                            start: { actions.startWork(row.checkout, $0) })
                            .id(row.checkout.id)
                    }
                    taskCard(row)
                    checkoutCard(row)
                    branchesCard(row)
                }
            }
        } else {
            // Blank without a selection, as the other sections' details.
            Color.clear
        }
    }

    // MARK: Header

    /// The state's tile and badge, the name, the path, the ahead and behind chips, and the actions.
    private func header(_ row: WorkspaceRowModel) -> some View {
        DetailHeader(title: row.checkout.name) {
            WorkspaceTile(kind: row.kind, size: 22)
            WorkspaceBadge(row: row)
        } menu: {
            Button("Copy Path") { actions.copy(row.checkout.path) }
            if let branch = row.branch {
                Button("Copy Branch Name") { actions.copy(branch) }
            }
        } byline: {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: row.shownPath(home: home))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(row.checkout.path)
                if row.kind == .free {
                    Text(verbatim: "Clean on \(row.checkout.baseBranch): ready for the next task.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } chips: {
            if let compact = row.aheadBehind?.compact {
                DetailChip(
                    symbol: "arrow.up.arrow.down", text: compact,
                    help: "Against origin/\(row.checkout.baseBranch): \(row.aheadBehind?.words ?? "")")
            }
            if row.hasStaleBase, let behind = row.localBaseBehind {
                DetailChip(
                    symbol: "exclamationmark.triangle.fill", tint: .yellow, text: "Local \(row.checkout.baseBranch) \(behind) behind",
                    help: "Your local \(row.checkout.baseBranch) is \(behind) behind origin/\(row.checkout.baseBranch)")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                actionRow(row)
                if let note = row.actionNote {
                    StatusLine(.ok, note)
                }
                if let problem = row.actionProblem {
                    StatusLine(.problem, problem)
                }
                if let problem = row.problem {
                    StatusLine(.problem, problem)
                }
            }
            .padding(.top, 4)
        }
    }

    /// Every frequent action as a visible button; Open in IDE is the prominent one.
    private func actionRow(_ row: WorkspaceRowModel) -> some View {
        DetailActionRow {
            Button {
                actions.openInIDE(row.checkout)
            } label: {
                HStack(spacing: 6) {
                    if row.isOpeningInIDE {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                    Text("Open in IDE")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasIDECommand || row.isOpeningInIDE)
            .help(hasIDECommand ? "Run your Open in IDE command for \(row.checkout.name)" : "Set the command in Settings → Repositories")
            DetailActionButton("Open in Terminal", "terminal", help: "Open \(row.checkout.name) in your terminal") {
                actions.openInTerminal(row.checkout)
            }
            DetailActionButton("Reveal in Finder", "folder", help: "Show \(row.checkout.name) in Finder") {
                actions.revealInFinder(row.checkout)
            }
            if !hasIDECommand {
                Button("Set Up IDE…") { actions.openSettings(.ideCommand) }
                    .buttonStyle(.link)
            }
        }
    }

    // MARK: Task

    /// The work item, the merge request and its Jenkins build; a branch without a number has no work item row. Nothing
    /// for a checkout on its base branch.
    @ViewBuilder
    private func taskCard(_ row: WorkspaceRowModel) -> some View {
        let onTask = row.branch != nil && row.branch != row.checkout.baseBranch
        if onTask {
            DetailCard("Task", symbol: "checklist") {
                VStack(alignment: .leading, spacing: 0) {
                    if let number = row.number {
                        taskRow("Work Item") {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                WorkItemNumberChip(text: number)
                                    .fixedSize()
                                Text(verbatim: row.title)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            if row.titleFromBranch {
                                Text("Not among the loaded work items: the title is the branch's")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } buttons: {
                            if let url = row.task.workItemURL {
                                smallButton("Show", help: "Show it in Work Items, or under Opened") { actions.follow(url) }
                                smallButton("Open in GitLab", help: "Open the work item in GitLab") { actions.open(url) }
                            }
                        }
                        Divider().padding(.vertical, 8)
                    }
                    if let mergeRequest = row.task.mergeRequest, let status = row.status {
                        taskRow("Merge Request") {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if let reference = row.mergeRequestReference {
                                    MergeRequestNumberChip(text: reference)
                                        .fixedSize()
                                }
                                Text(verbatim: mergeRequest.title)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            StatusBadge(text: status.text, symbol: status.symbol, tint: status.color.swiftUI)
                        } buttons: {
                            smallButton("Show", help: "Show it in Merge Requests") {
                                actions.showInMergeRequests(mergeRequest.id)
                            }
                            smallButton("Open in GitLab", help: "Open the merge request in GitLab") {
                                actions.open(mergeRequest.webURL)
                            }
                        }
                    } else {
                        taskRow("Merge Request") {
                            Text("None for this branch")
                                .foregroundStyle(.secondary)
                        } buttons: {}
                    }
                    if let build = row.task.build, let text = row.buildText, let state = row.build {
                        Divider().padding(.vertical, 8)
                        taskRow("Jenkins Build") {
                            SymbolText(
                                symbol: state.symbol, style: state.color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary),
                                text: text)
                        } buttons: {
                            smallButton("Show in Pipelines", help: "Show the build in Pipelines") { actions.showInPipelines(build.job) }
                        }
                    } else if row.task.mergeRequest != nil {
                        Divider().padding(.vertical, 8)
                        taskRow("Jenkins Build") {
                            Text("Not in Pipelines")
                                .foregroundStyle(.secondary)
                        } buttons: {}
                    }
                }
            }
        }
    }

    /// A caption, what it is about, and the buttons that go with it, wrapping.
    private func taskRow<Body: View, Buttons: View>(
        _ caption: String, @ViewBuilder body: () -> Body, @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            body()
            PillFlowLayout(spacing: 6, lineSpacing: 6) {
                buttons()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func smallButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(help)
    }

    // MARK: Checkout

    /// The branch, the changed files, ahead and behind `origin/<base>`, and the local base branch.
    @ViewBuilder
    private func checkoutCard(_ row: WorkspaceRowModel) -> some View {
        let base = row.checkout.baseBranch
        if row.kind == .unknown {
            SkeletonCard(title: "Checkout", symbol: "arrow.triangle.branch", lines: 4)
        } else if row.kind != .problem {
            DetailCard("Checkout", symbol: "arrow.triangle.branch") {
                VStack(alignment: .leading, spacing: 0) {
                    fact("Branch") {
                        let branch = row.branch ?? (row.kind == .detached ? "Detached HEAD" : "—")
                        Text(verbatim: branch)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(branch)
                    }
                    Divider().padding(.vertical, 7)
                    fact("Changes") {
                        Text(verbatim: row.changesInDetail ?? "—")
                            .foregroundStyle(row.kind == .changed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                    }
                    Divider().padding(.vertical, 7)
                    fact("Against origin/\(base)") {
                        Text(verbatim: row.aheadBehind?.words ?? "origin/\(base) unknown")
                            .foregroundStyle(row.aheadBehind == nil ? .secondary : .primary)
                            .monospacedDigit()
                    }
                    Divider().padding(.vertical, 7)
                    fact("Local \(base)") {
                        if let behind = row.localBaseBehind {
                            if row.hasStaleBase {
                                SymbolText(
                                    symbol: "exclamationmark.triangle.fill", style: AnyShapeStyle(Color.yellow),
                                    text: "\(behind) behind origin/\(base)")
                            } else {
                                Text(verbatim: behind == 0 ? "Even with origin/\(base)" : "\(behind) behind origin/\(base)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        } else {
                            Text("No local branch")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(verbatim: footer(base: base))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
            }
        }
    }

    /// A label and its value on one line, the value taking what the label leaves and truncating in the middle.
    private func fact<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            value()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: Local branches

    /// The checkout's local branches without a merge request: how they stand to their remote branch and to the base, the
    /// last commit, and "Create Merge Request" for a pushed one (WS-06).
    @ViewBuilder
    private func branchesCard(_ row: WorkspaceRowModel) -> some View {
        let title = "Local Branches Without a Merge Request"
        if let branches = row.localBranches {
            DetailCard(title, symbol: "arrow.triangle.pull", width: .fullWidth) {
                VStack(alignment: .leading, spacing: 0) {
                    if let problem = branches.problem {
                        StatusLine(.problem, problem)
                    } else if branches.rows.isEmpty {
                        Text("No local branch without a merge request")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(branches.rows.enumerated()), id: \.element.id) { index, branch in
                            if index > 0 {
                                Divider().padding(.vertical, 8)
                            }
                            LocalBranchRowView(branch: branch) {
                                if let url = branch.newMergeRequest {
                                    actions.open(url)
                                }
                            }
                        }
                    }
                    if branches.problem == nil {
                        Text(verbatim: "\(branches.total) local branch\(branches.total == 1 ? "" : "es") in all. Merge requests are the ones loaded for you; origin is as of your last fetch.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                    }
                }
            }
        } else if row.kind != .unknown, row.kind != .problem {
            // Read when a checkout is selected: bars until the branches are in.
            SkeletonCard(title: title, symbol: "arrow.triangle.pull", lines: 3, width: .fullWidth)
        }
    }

    /// "Read with git 2m ago, read-only. origin/develop is as of your last fetch: the app never fetches."
    private func footer(base: String) -> String {
        let read = readAt.map { "Read with git \(GitLabText.age(since: $0, now: now)) ago, read-only." }
            ?? "Read with git, read-only."
        return "\(read) origin/\(base) is as of your last fetch: the app never fetches."
    }
}

/// A local branch in the detail: its name, how it stands to its remote branch and to the base, its last commit, and
/// "Create Merge Request" for a pushed one.
private struct LocalBranchRowView: View {
    let branch: LocalBranchRow
    let createMergeRequest: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: branch.name)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(branch.name)
                    if branch.isCurrent {
                        Text("checked out")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: [branch.remote, branch.base].compactMap(\.self).joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(verbatim: branch.lastCommit)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if branch.isPushed {
                Button("Create Merge Request", action: createMergeRequest)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(branch.newMergeRequest == nil)
                    .help(branch.newMergeRequest == nil
                        ? "Set GitLab and the project in Settings → Projects"
                        : "Open GitLab's new merge request page for \(branch.name)")
            }
        }
        .padding(.vertical, 2)
    }
}
