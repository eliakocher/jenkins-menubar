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

/// The detail drawn from plain values, for the window and the gallery: a grouped `Form` with the header and the
/// actions, the task, and the checkout's git state.
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
            Form {
                Section {
                    if row.kind == .free {
                        Text(verbatim: "Clean on \(row.checkout.baseBranch): ready for the next task.")
                            .foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { actionButtons(row) }
                        VStack(alignment: .leading, spacing: 6) { actionButtons(row) }
                    }
                    .padding(.vertical, 2)
                    if let note = row.actionNote {
                        StatusLine(.ok, note)
                    }
                    if let problem = row.actionProblem {
                        StatusLine(.problem, problem)
                    }
                    ClaudeCodeLaunchLine(context: .workspace(row.checkout, task: row.task))
                    if let problem = row.problem {
                        StatusLine(.problem, problem)
                    }
                } header: {
                    header(row)
                }
                if row.kind == .free {
                    StartWorkSection(
                        checkout: row.checkout, items: startWorkItems, isRunning: row.isStartingWork,
                        start: { actions.startWork(row.checkout, $0) })
                        .id(row.checkout.id)
                }
                taskSection(row)
                checkoutSection(row)
                branchesSection(row)
            }
            .formStyle(.grouped)
        } else {
            // Blank without a selection, as the other sections' details.
            Color.clear
        }
    }

    /// The tile, the folder's name with "Free", and the path; the actions are the section's first row.
    private func header(_ row: WorkspaceRowModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                WorkspaceTile(kind: row.kind, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: row.checkout.name)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        WorkspaceBadge(row: row)
                    }
                    Text(verbatim: row.shownPath(home: home))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(row.checkout.path)
                }
            }
        }
        .font(.body)
        .textCase(nil)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func actionButtons(_ row: WorkspaceRowModel) -> some View {
        Button {
            actions.openInIDE(row.checkout)
        } label: {
            HStack(spacing: 6) {
                if row.isOpeningInIDE {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Open in IDE")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!hasIDECommand || row.isOpeningInIDE)
        .help(hasIDECommand ? "Run your Open in IDE command for \(row.checkout.name)" : "Set the command in Settings → Repositories")
        Button("Open in Terminal") { actions.openInTerminal(row.checkout) }
            .buttonStyle(.bordered)
        // Claude Code in this checkout, with its task as the first prompt (AI-05).
        OpenInClaudeCodeButton(context: .workspace(row.checkout, task: row.task))
        Button("Reveal in Finder") { actions.revealInFinder(row.checkout) }
            .buttonStyle(.bordered)
        if !hasIDECommand {
            Button("Set Up IDE…") { actions.openSettings() }
                .buttonStyle(.link)
        }
    }

    /// The work item, the merge request and its Jenkins build; a branch without a number has no work item row.
    @ViewBuilder
    private func taskSection(_ row: WorkspaceRowModel) -> some View {
        let onTask = row.branch != nil && row.branch != row.checkout.baseBranch
        if onTask {
            Section {
                if let number = row.number {
                    LabeledContent {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let url = row.task.workItemURL {
                                Button("Open") { actions.open(url) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(number)  \(row.title)")
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            if row.titleFromBranch {
                                Text("Not among the loaded work items: the title is the branch's")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let mergeRequest = row.task.mergeRequest, let status = row.status {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Button("Show") { actions.showInMergeRequests(mergeRequest.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Show it in Merge Requests")
                            Button("Open") { actions.open(mergeRequest.webURL) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Open it in GitLab")
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: "\(row.mergeRequestReference ?? "")  \(mergeRequest.title)")
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            StatusBadge(text: status.text, symbol: status.symbol, tint: status.color.swiftUI)
                        }
                    }
                } else {
                    LabeledContent("Merge request") {
                        Text("None for this branch")
                            .foregroundStyle(.secondary)
                    }
                }
                if let build = row.task.build, let text = row.buildText, let state = row.build {
                    LabeledContent("Jenkins build") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            SymbolText(
                                symbol: state.symbol, style: state.color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary),
                                text: text)
                            Button("Show in Pipelines") { actions.showInPipelines(build.job) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                } else if row.task.mergeRequest != nil {
                    LabeledContent("Jenkins build") {
                        Text("Not in Pipelines")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Task")
            }
        }
    }

    /// The checkout's local branches without a merge request: how they stand to their remote branch and to the base, the
    /// last commit, and "Create Merge Request" for a pushed one (WS-06).
    @ViewBuilder
    private func branchesSection(_ row: WorkspaceRowModel) -> some View {
        if let branches = row.localBranches {
            Section {
                if let problem = branches.problem {
                    StatusLine(.problem, problem)
                } else if branches.rows.isEmpty {
                    Text("No local branch without a merge request")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(branches.rows) { branch in
                        LocalBranchRowView(branch: branch) {
                            if let url = branch.newMergeRequest {
                                actions.open(url)
                            }
                        }
                    }
                }
            } header: {
                Text("Local Branches Without a Merge Request")
            } footer: {
                if branches.problem == nil {
                    Text(verbatim: "\(branches.total) local branch\(branches.total == 1 ? "" : "es") in all. Merge requests are the ones loaded for you; origin is as of your last fetch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The branch, the changed files, ahead and behind `origin/<base>`, and the local base branch.
    private func checkoutSection(_ row: WorkspaceRowModel) -> some View {
        let base = row.checkout.baseBranch
        return Section {
            LabeledContent("Branch") {
                Text(verbatim: row.branch ?? (row.kind == .detached ? "Detached HEAD" : "—"))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            LabeledContent("Changes") {
                Text(verbatim: row.changesInDetail ?? "—")
                    .foregroundStyle(row.kind == .changed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
            }
            LabeledContent("Against origin/\(base)") {
                Text(verbatim: row.aheadBehind?.words ?? "origin/\(base) unknown")
                    .foregroundStyle(row.aheadBehind == nil ? .secondary : .primary)
                    .monospacedDigit()
            }
            LabeledContent("Local \(base)") {
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
        } header: {
            Text("Checkout")
        } footer: {
            Text(verbatim: footer(base: base))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
