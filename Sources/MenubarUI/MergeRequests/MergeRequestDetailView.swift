import MenubarCore
import SwiftUI

/// The Merge Requests section's detail column (Task 5.3, `docs/design/merge-requests.md`): the selected merge request's
/// status, author and age, pipeline, diff stats, Jenkins build, reviewers, approvals, unresolved threads, GitLab pipeline,
/// description and links; blank without one, or when it left the list.
///
/// It looks the merge request up in the store and its build in Pipelines, both in memory; only the description and the
/// GitLab details load on selection (WIN-02, MR-06 to MR-08). The ages refresh every 10 s.
public struct MergeRequestDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    private let selection: MergeRequest.ID?

    /// - Parameter selection: the selected merge request, by its web URL
    public init(selection: MergeRequest.ID?) {
        self.selection = selection
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            MergeRequestDetailContent(model: detail(at: context.date), actions: .live(model: model, router: router, openURL: openURL))
        }
        .workspaceTagsClickable()
    }
}

extension MergeRequestDetailView {
    /// The selected merge request's detail, with the easter egg line under its diff stats when they call for one.
    private func detail(at date: Date) -> MergeRequestDetailModel? {
        var detail = MergeRequestDetailModel(MergeRequestsData(model, now: date), selection: selection)
        if let mergeRequest = detail?.mergeRequest {
            detail?.workItems = model.workItems(ofMergeRequest: mergeRequest.reference, title: mergeRequest.title)
        }
        if model.pipelines.preferences.easterEggs, let stats = detail?.mergeRequest.diffStats {
            detail?.eggLine = EggRules.diffLine(stats)
        }
        return detail
    }
}

/// The detail drawn from plain values, for the window and the gallery: a scrolling page of cards. On top the header:
/// the state badge, the project's name and the iid, the title, the author and the age, and a strip of chips for the
/// pipeline, the Jenkins build, the approvals, the threads and the diff, each jumping to its card or opening its page.
/// Below, the compact cards in one column, or two when wide: Reviewers, Approvals, Builds; then the tall ones, full
/// width: Description, Claude, Changes, Discussion. "Open in GitLab" is in the toolbar.
struct MergeRequestDetailContent: View {
    let model: MergeRequestDetailModel?
    let actions: GitLabSectionActions

    @Environment(AppModel.self) private var appModel: AppModel?

    /// the merge request and update whose links to work items were last asked for
    private struct LinksAsk: Hashable {
        var id: MergeRequest.ID
        var updatedAt: Date
    }

    /// the cards the chips jump to
    private enum Card: Hashable {
        case approvals
        case discussion
        case builds
        case changes
        /// the chat with Claude about the code (AI-07)
        case claude
    }

    var body: some View {
        if let model {
            MergeRequestDetailsReader(mergeRequest: model.mergeRequest) { state, retry in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            header(model, state: state) { card in
                                withAnimation(.snappy) { proxy.scrollTo(card, anchor: .top) }
                            }
                            // Compact fact cards in two columns when wide; the tall ones below, full width, in a fixed order:
                            // Description, Claude, Changes, Discussion.
                            CardColumnsLayout {
                                // Each reviewer with their review, and Re-request Review where a review was given (MR-09, MR-10).
                                ReviewersCard(model: model, actions: actions)
                                // Loaded on selection, as the threads and the GitLab pipeline (MR-06 to MR-08).
                                ApprovalsCard(state: state, retry: retry)
                                    .id(Card.approvals)
                                BuildsCard(
                                    model: model, pipeline: state.details?.pipeline, actions: actions, isLoading: state.isAwaiting)
                                    .id(Card.builds)
                                // Loaded on selection (WIN-02).
                                DescriptionSection(source: DescriptionSource(model.mergeRequest), inCard: true)
                                // The inline chat with Claude about the code, while the Claude features are on (AI-07).
                                MergeRequestClaudeCard(mergeRequest: model.mergeRequest)
                                    .id(Card.claude)
                                // The code itself, read only, folded where it is big or generated (MR-11).
                                ChangesCard(mergeRequest: model.mergeRequest, changesURL: model.changesURL, actions: actions)
                                    .id(Card.changes)
                                // With Summarize Discussion while the Claude features are on (AI-03).
                                DiscussionCard(
                                    details: state.details, mergeRequest: model.mergeRequest, actions: actions,
                                    // The discussions come apart from the approvals and the pipeline (OD-07).
                                    isLoading: state.isAwaiting || state.details?.discussionsLoaded == false)
                                    .id(Card.discussion)
                            }
                        }
                        .pageContentWidth()
                    }
                    // Another merge request starts at the top, with its own disclosures and re-request state.
                    .id(model.mergeRequest.id)
                    // GitLab's links to the work items, once per update of the merge request (MR-12).
                    .task(id: LinksAsk(id: model.mergeRequest.id, updatedAt: model.mergeRequest.updatedAt)) {
                        await appModel?.loadItemLinks(
                            ofMergeRequest: model.mergeRequest.reference, webURL: model.mergeRequest.webURL,
                            updatedAt: model.mergeRequest.updatedAt)
                    }
                    // "Ask Claude" about lines, a file or the whole merge request sets the chat's scope chip; its card, with
                    // the field at the bottom, comes into view.
                    .askClaudeAboutCode(model.mergeRequest) {
                        withAnimation(.snappy) { proxy.scrollTo(Card.claude, anchor: .bottom) }
                    }
                }
            }
        } else {
            // Blank without a selection: nothing says "select something" next to a list that may have nothing to select.
            Color.clear
        }
    }

    // MARK: The header

    private func header(
        _ model: MergeRequestDetailModel, state: MergeRequestDetailsState, jump: @escaping (Card) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                StatusBadge(text: model.status.text, symbol: model.status.symbol, tint: model.status.color.swiftUI)
                // The reference as the small green chip (whatever the state: the badge before it says that), then the project.
                ReferenceChip(kind: .mergeRequest, text: "!\(String(model.mergeRequest.iid))", help: model.mergeRequest.reference)
                    .fixedSize()
                    .textSelection(.enabled)
                Text(verbatim: model.projectName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                // The checkout the branch lives in; a click shows it in Workspaces (WS-07).
                WorkspaceTag(subject: .mergeRequest(model.mergeRequest))
            }
            Text(verbatim: model.mergeRequest.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                InitialsAvatar(name: model.mergeRequest.author.name, username: model.mergeRequest.author.username, size: 18)
                Text(verbatim: "\(model.author) · updated \(model.updated)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            chips(model, state: state, jump: jump)
                .padding(.top, 4)
            // The frequent actions as buttons.
            actionRow(model)
            if let eggLine = model.eggLine {
                Text(verbatim: eggLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// The pipeline, the Jenkins build, the approvals, the threads and the diff, wrapping when narrow.
    private func chips(
        _ model: MergeRequestDetailModel, state: MergeRequestDetailsState, jump: @escaping (Card) -> Void
    ) -> some View {
        let green = MergeRequestStatus.Color.green.swiftUI
        let red = MergeRequestStatus.Color.red.swiftUI
        let hasBuildsCard = state.details?.pipeline != nil || model.jenkinsBuild != nil || model.watch != .hidden
        return PillFlowLayout(spacing: 6, lineSpacing: 6) {
            // One chip for the pipeline: the Jenkins build when the app knows it, else GitLab's (MR-14).
            switch MergeRequestPipelineChip.of(model) {
            case .jenkins(let help):
                if let build = model.jenkinsBuild {
                    DetailChip(symbol: build.state.symbol, tint: build.state.color ?? .secondary, text: build.chip, help: help) {
                        actions.showInPipelines(build.job)
                    }
                }
            case .gitLab:
                if let pipeline = model.pipeline {
                    DetailChip(
                        symbol: pipeline.symbol, tint: pipeline.tint.chipColor, text: "Pipeline \(pipeline.word)",
                        help: hasBuildsCard ? "Jump to the Builds card" : "Open the merge request's pipelines in GitLab"
                    ) {
                        if hasBuildsCard { jump(.builds) } else { actions.open(model.pipelinesURL) }
                    }
                }
            case .none:
                DetailChip(symbol: "circle.dashed", text: "No pipeline")
            case .hidden:
                EmptyView()
            }
            // The work item the title names or GitLab links, the blue "#19202" (MR-12).
            WorkItemLinkChips(
                items: model.workItems, project: Self.project(of: model.mergeRequest.reference), actions: actions.itemLinks)
            if let details = state.details {
                let approvals = details.approvals
                let satisfied = approvals.isSatisfied == true
                DetailChip(
                    symbol: satisfied ? "checkmark.seal.fill" : "checkmark.seal", tint: satisfied ? green : .secondary,
                    text: approvals.summary, help: "Jump to the Approvals card"
                ) {
                    jump(.approvals)
                }
                if !details.threads.isEmpty {
                    let count = details.threads.count
                    DetailChip(
                        symbol: "bubble.left.and.bubble.right.fill", tint: MergeRequestStatus.Color.orange.swiftUI,
                        text: "\(count)\(details.hasMoreDiscussions ? "+" : "") open \(count == 1 ? "thread" : "threads")",
                        help: "Jump to the open threads in the Discussion card"
                    ) {
                        jump(.discussion)
                    }
                } else if details.resolvedThreadCount > 0 {
                    DetailChip(symbol: "checkmark.bubble.fill", tint: green, text: "Threads resolved", help: "Jump to the Discussion card") {
                        jump(.discussion)
                    }
                }
            } else if state.failed == false {
                SkeletonBlock(width: 104, height: 24)
                    .skeletonShimmer(announces: false)
            }
            let stats = model.mergeRequest.diffStats ?? MergeRequest.DiffStats(additions: 0, deletions: 0, fileCount: 0)
            DetailChip(symbol: "doc.text.magnifyingglass", help: "Jump to the Changes card", action: { jump(.changes) }) {
                HStack(spacing: 4) {
                    Text(verbatim: "+\(String(stats.additions))")
                        .foregroundStyle(green)
                    Text(verbatim: "−\(String(stats.deletions))")
                        .foregroundStyle(red)
                    Text(verbatim: "· \(String(stats.fileCount)) \(stats.fileCount == 1 ? "file" : "files")")
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "group/project" of `group/project!12`, whose work items show as "#123"
    private static func project(of reference: String) -> String {
        reference.split(separator: "!").dropLast().joined(separator: "!")
    }

    /// Copy Link, Ask Claude while the Claude features are on, and the follow-up item (NEW-04), as the build detail has its
    /// buttons. GitLab's pages are in the toolbar, the Changes card and the Builds card.
    private func actionRow(_ model: MergeRequestDetailModel) -> some View {
        DetailActionRow {
            CopyLinkButton(help: "Copies the merge request's link in GitLab") { actions.copy(model.mergeRequest.webURL) }
            AskClaudeAboutMergeRequestButton()
            // GitLab's new issue page, prefilled with this merge request's link (NEW-04).
            if let newWorkItem = actions.newWorkItem {
                DetailActionButton(
                    "New Follow-Up Item", "plus.square.on.square",
                    help: "Opens GitLab's new issue page, filled in from this merge request"
                ) {
                    newWorkItem(.followUp(model.mergeRequest))
                }
            }
        }
        .padding(.top, 2)
    }
}

/// "Ask Claude" as a button of the merge request's action row: it aims the Claude card's chat at the whole merge request
/// (AI-07); nothing while Claude is off.
private struct AskClaudeAboutMergeRequestButton: View {
    @Environment(\.askClaudeAboutCode) private var ask

    var body: some View {
        if let ask {
            DetailActionButton("Ask Claude", "sparkles", help: "Asks Claude about this merge request's code") { ask(.mergeRequest) }
        }
    }
}

/// A fact's value: a symbol in its color, then its words in the label color, which wrap and can be selected.
struct SymbolText: View {
    let symbol: String
    let style: AnyShapeStyle
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(style)
            Text(verbatim: text)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

extension MergeRequestDetailModel.Tint {
    /// the symbol's style
    var style: AnyShapeStyle {
        switch self {
        case .label: AnyShapeStyle(.primary)
        case .secondary: AnyShapeStyle(.secondary)
        case .green: AnyShapeStyle(Color.green)
        case .red: AnyShapeStyle(Color.red)
        }
    }

    /// the tint of the header's chip: a running pipeline in blue, the quiet states grey
    var chipColor: Color {
        switch self {
        case .label: MergeRequestStatus.Color.blue.swiftUI
        case .secondary: .secondary
        case .green: MergeRequestStatus.Color.green.swiftUI
        case .red: MergeRequestStatus.Color.red.swiftUI
        }
    }
}

extension MergeRequestDetailsState {
    /// whether GitLab's details are still on their way: nothing loaded yet, and no failure to show instead
    var isAwaiting: Bool { details == nil && !failed }
}
