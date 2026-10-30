import MenubarCore
import SwiftUI

/// Hands the merge request's GitLab details (MR-06 to MR-08) to the detail's cards, and loads them on selection.
///
/// They come from `AppModel.mergeRequestDetails` or the gallery's ``MergeRequestDetailsFixtures``, once per merge
/// request and update. Read only: every link opens a page in the browser.
struct MergeRequestDetailsReader<Content: View>: View {
    let mergeRequest: MergeRequest
    /// the content, with the details' state and the retry after a failure
    @ViewBuilder let content: (MergeRequestDetailsState, @escaping () -> Void) -> Content

    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.mergeRequestDetailsFixtures) private var fixtures
    /// the merge request and update last asked for, so that a state change for the same one doesn't ask again
    @ViewState private var asked: Ask?

    private struct Ask: Hashable {
        var id: MergeRequest.ID
        var updatedAt: Date
    }

    var body: some View {
        let state = fixtures?.states[mergeRequest.reference] ?? model?.mergeRequestDetails.state(of: mergeRequest) ?? .loading
        content(state, retry)
            .task(id: Ask(id: mergeRequest.id, updatedAt: mergeRequest.updatedAt)) { await load() }
    }

    private func retry() {
        asked = nil
        Task { await load() }
    }

    /// Asks the store once per merge request and update.
    private func load() async {
        let ask = Ask(id: mergeRequest.id, updatedAt: mergeRequest.updatedAt)
        guard fixtures == nil, let model, asked != ask else {
            return
        }
        asked = ask
        await model.mergeRequestDetails.load(mergeRequest)
    }
}

// MARK: - Approvals

/// "1 of 2 approvals" as a bar of one segment per approval needed, who approved, and the rules folded away below:
/// the open ones first, each once, file patterns named (MR-06). Skeleton bars while loading, "Try Again" after a
/// failure.
struct ApprovalsCard: View {
    let state: MergeRequestDetailsState
    let retry: () -> Void

    @ViewState private var showsRules = false

    var body: some View {
        DetailCard("Approvals", symbol: "checkmark.seal") {
            if let approvals = state.details?.approvals {
                content(approvals)
            } else if state.failed {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("The details couldn't be loaded")
                        .foregroundStyle(.secondary)
                    Button("Try Again", action: retry)
                        .buttonStyle(.link)
                }
            } else {
                // The height of the real content: the segments' bar and the line of who approved.
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(height: 8)
                    SkeletonBlock(width: 150, height: 10, lineHeight: 20)
                }
                .skeletonShimmer()
            }
        } accessory: {
            if let approvals = state.details?.approvals {
                summary(approvals)
            }
        }
    }

    @ViewBuilder
    private func summary(_ approvals: MergeRequestDetails.Approvals) -> some View {
        let tint = approvals.isSatisfied == true ? MergeRequestStatus.Color.green.swiftUI : Color.secondary
        HStack(spacing: 4) {
            if approvals.isSatisfied == true {
                Image(systemName: "checkmark.circle.fill")
            }
            Text(verbatim: approvals.summary)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(tint)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func content(_ approvals: MergeRequestDetails.Approvals) -> some View {
        let rules = ApprovalRuleList(approvals.rules)
        VStack(alignment: .leading, spacing: 12) {
            if let required = approvals.required, required > 0 {
                ApprovalBar(approved: approvals.approvedBy.count, required: required)
            }
            if approvals.approvedBy.isEmpty {
                Text(approvals.required == 0 ? "None needed" : "Nobody approved yet")
                    .foregroundStyle(.secondary)
            } else {
                PillFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(approvals.approvedBy, id: \.username) { person in
                        PersonChip(person: person)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !rules.lines.isEmpty {
                DisclosureGroup(isExpanded: $showsRules) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rules.lines) { line in
                            RuleLine(line: line)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 6) {
                        Text("Rules")
                            .fontWeight(.medium)
                        Text(verbatim: rules.openCount == 0 ? "all satisfied" : "\(rules.openCount) open")
                            .foregroundStyle(rules.openCount == 0 ? MergeRequestStatus.Color.green.swiftUI : MergeRequestStatus.Color.orange.swiftUI)
                    }
                    .font(.callout)
                    .contentShape(.rect)
                    .onTapGesture { withAnimation(.snappy) { showsRules.toggle() } }
                }
            }
        }
    }
}

/// One segment per approval needed, green as far as approved; a plain bar beyond 12.
struct ApprovalBar: View {
    let approved: Int
    let required: Int

    var body: some View {
        let green = MergeRequestStatus.Color.green.swiftUI
        Group {
            if required <= 12 {
                HStack(spacing: 3) {
                    ForEach(0..<required, id: \.self) { index in
                        Capsule()
                            .fill(index < approved ? AnyShapeStyle(green.gradient) : AnyShapeStyle(.quaternary))
                    }
                }
            } else {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(green.gradient)
                            .frame(width: proxy.size.width * min(1, CGFloat(approved) / CGFloat(required)))
                    }
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("\(approved) of \(required) approvals")
    }
}

/// A person who approved: their avatar and name in a quiet capsule.
private struct PersonChip: View {
    let person: MergeRequest.Person

    var body: some View {
        HStack(spacing: 5) {
            InitialsAvatar(name: person.name, username: person.username, size: 18)
            Text(verbatim: person.displayName)
                .lineLimit(1)
        }
        .font(.callout)
        .padding(.leading, 3)
        .padding(.trailing, 9)
        .padding(.vertical, 3)
        .background(.fill.quaternary, in: Capsule())
    }
}

/// A rule: done or not, its name, "1 of 2" and who approved under it; a satisfied one dimmed.
private struct RuleLine: View {
    let line: ApprovalRuleList.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: line.isSatisfied ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(line.isSatisfied ? MergeRequestStatus.Color.green.swiftUI : MergeRequestStatus.Color.orange.swiftUI)
            VStack(alignment: .leading, spacing: 1) {
                name
                    .lineLimit(2)
                if !line.approvedBy.isEmpty {
                    Text(verbatim: line.approvedBy.map(\.displayName).formatted(.list(type: .and, width: .narrow)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: line.progress)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .opacity(line.isSatisfied ? 0.6 : 1)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var name: some View {
        switch line.name {
        case .files(let pattern):
            Text("Files matching \(Text(verbatim: pattern).font(.system(.callout, design: .monospaced)))")
        case .named, .allFiles:
            Text(verbatim: line.name.text)
        }
    }
}

extension MergeRequest.Person {
    /// the name, else "@username" for a person without one
    var displayName: String {
        name.isEmpty ? "@\(username)" : name
    }
}

// MARK: - Discussion

/// The open threads: each with its first comment, who wrote it, where on the diff and the text as Markdown, then the
/// replies behind a thin bar, folded to the last two when long; cut after 5 threads with "Show All (N)" (MR-07). Under them, while the Claude features are on, Summarize Discussion and Open in
/// Claude Code with Claude's answer (AI-03, AI-05). Nothing when there is neither.
struct DiscussionCard: View {
    let details: MergeRequestDetails?
    let mergeRequest: MergeRequest
    let actions: GitLabSectionActions
    /// whether the details are still on their way, so the threads' place shows skeleton lines
    var isLoading = false

    @Environment(AppModel.self) private var model: AppModel?
    @ViewState private var showsAll = false
    private let threadOrder = DiscussionOrder()
    /// the threads the user opened, kept while the card stays on screen
    @ViewState private var expanded: Set<String> = []

    private static let cut = 5

    var body: some View {
        let threads = details?.threads ?? []
        let resolved = details?.resolvedThreadCount ?? 0
        let offersClaude = model?.ai.isOffered == true
        if !threads.isEmpty || resolved > 0 || offersClaude || isLoading {
            DetailCard("Discussion", symbol: "bubble.left.and.bubble.right", width: .fullWidth) {
                VStack(alignment: .leading, spacing: 10) {
                    if isLoading, details == nil {
                        SkeletonLines(count: 4)
                    } else if !threads.isEmpty || !(details?.resolvedThreads.isEmpty ?? true) {
                        threadList(threads)
                    } else if resolved > 0 {
                        SymbolText(
                            symbol: "checkmark.circle.fill", style: AnyShapeStyle(MergeRequestStatus.Color.green.swiftUI),
                            text: resolved == 1 ? "The thread is resolved" : "All \(resolved) threads are resolved")
                    }
                    if let model, offersClaude {
                        if !threads.isEmpty || resolved > 0 || (isLoading && details == nil) {
                            Divider()
                        }
                        ClaudeDiscussion(model: model, mergeRequest: mergeRequest)
                    }
                }
            } accessory: {
                HStack(spacing: 8) {
                    if !threads.isEmpty {
                        CountBadge(
                            text: "\(threads.count)\(details?.hasMoreDiscussions == true ? "+" : "") open",
                            tint: MergeRequestStatus.Color.orange.swiftUI)
                    }
                    if threads.count + (details?.resolvedThreads.count ?? 0) > 1 {
                        CommentSortMenu()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func threadList(_ threads: [MergeRequestDetails.ReviewThread]) -> some View {
        // The user's order: by last activity, the open threads before the resolved ones (each folded to a line) or not.
        let all = threadOrder.order.ordered(
            threads.map { $0.comment } + (details?.resolvedThreads ?? []).map { $0.comment(isResolved: true) })
        let shown = showsAll ? all : Array(all.prefix(Self.cut))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown) { thread in
                CommentThreadView(thread: thread, base: mergeRequest.webURL, expanded: $expanded) { actions.open($0) }
            }
        }
        HStack(spacing: 12) {
            if all.count > Self.cut {
                Button(showsAll ? "Show Less" : "Show All (\(all.count))") {
                    withAnimation(.snappy) { showsAll.toggle() }
                }
            }
            if details?.hasMoreDiscussions == true {
                Button("More Threads in GitLab") { actions.open(mergeRequest.webURL) }
            }
        }
        .buttonStyle(.link)
    }
}

/// Summarize Discussion and Open in Claude Code, with Claude's summary (AI-03, AI-05): the merge request detail's Claude
/// rows inside its Discussion card.
private struct ClaudeDiscussion: View {
    let model: AppModel
    let mergeRequest: MergeRequest

    var body: some View {
        let subject = AISubject.mergeRequest(mergeRequest.reference)
        let state = model.ai.state(of: subject)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ClaudeActionButton(
                    title: "Summarize Discussion", systemImage: "sparkles", prominent: true,
                    help: "Ask Claude what the review threads agreed, what is open and who it waits on.",
                    isDisabled: state.isBusy
                ) { picked in
                    Task { await model.ai.summarize(mergeRequest, model: picked) }
                }
                OpenInClaudeCodeButton(context: .mergeRequest(mergeRequest))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            ClaudeCodeLaunchLine(context: .mergeRequest(mergeRequest))
            AIAnswerRows(
                state: state, subject: subject, item: .mergeRequest(mergeRequest),
                send: { Task { await model.ai.send(subject) } }, dismiss: { model.ai.dismiss(subject) }
            ) { answer in
                if let summary = answer.summary {
                    ThreadsSummaryCard(summary: summary)
                }
            }
        }
    }
}

// MARK: - Builds

/// The Jenkins build with Show in Pipelines and Watch Builds (WIN-02, WATCH-01), then the GitLab head pipeline: its
/// status, its stages as chips and the failed and running jobs, each opening its page (MR-08). Nothing when there is
/// neither.
struct BuildsCard: View {
    let model: MergeRequestDetailModel
    let pipeline: MergeRequestDetails.Pipeline?
    let actions: GitLabSectionActions
    /// whether the details are still on their way: the list knows the merge request has a pipeline, so its place shows
    /// skeleton lines
    var isLoading = false

    @ViewState private var showsAll = false

    private static let cut = 5

    var body: some View {
        let showsJenkins = model.jenkinsBuild != nil || model.watch != .hidden
        let awaitsPipeline = isLoading && pipeline == nil && model.pipeline != nil
        if showsJenkins || pipeline != nil || awaitsPipeline {
            DetailCard("Builds", symbol: "hammer") {
                VStack(alignment: .leading, spacing: 12) {
                    if showsJenkins {
                        jenkins
                    }
                    if showsJenkins, pipeline != nil || awaitsPipeline {
                        Divider()
                    }
                    if let pipeline {
                        gitLab(pipeline)
                    } else if awaitsPipeline {
                        SkeletonLines(count: 2)
                    }
                }
            } accessory: {
                Button("Pipelines in GitLab") { actions.open(model.pipelinesURL) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    // MARK: Jenkins

    private var jenkins: some View {
        VStack(alignment: .leading, spacing: 6) {
            SubHeading(text: "Jenkins")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    jenkinsState
                    Spacer(minLength: 8)
                    jenkinsButtons
                }
                VStack(alignment: .leading, spacing: 6) {
                    jenkinsState
                    HStack(spacing: 8) { jenkinsButtons }
                }
            }
        }
    }

    @ViewBuilder
    private var jenkinsState: some View {
        if let build = model.jenkinsBuild {
            SymbolText(
                symbol: build.state.symbol, style: build.state.color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary),
                text: build.text)
        } else {
            Text(model.watch.isWatching ? "No build yet" : "Not watched")
                .foregroundStyle(.secondary)
        }
    }

    /// "Show in Pipelines", then "Watch Builds" in one click, or "Watching"; nothing for my own MRs (WATCH-01).
    @ViewBuilder
    private var jenkinsButtons: some View {
        Group {
            if let build = model.jenkinsBuild {
                Button("Show in Pipelines") { actions.showInPipelines(build.job) }
            }
            switch model.watch {
            case .hidden:
                EmptyView()
            case .watch:
                Button("Watch Builds") { actions.watchBuilds(model.mergeRequest) }
                    .help("Watch all builds of this merge request")
            case .watching:
                Button("Watching") {}
                    .disabled(true)
                    .help("All builds of this merge request are watched")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: GitLab

    @ViewBuilder
    private func gitLab(_ pipeline: MergeRequestDetails.Pipeline) -> some View {
        let jobs = pipeline.jobs
        let attention = pipeline.needAttention
        let rest = jobs.filter { job in !attention.contains(where: { $0.id == job.id }) }
        let listed = showsAll ? attention + rest : Array(attention.prefix(Self.cut))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SubHeading(text: "GitLab")
                if let status = pipeline.status {
                    let fact = MergeRequestDetailModel.PipelineFact(status)
                    SymbolText(symbol: fact.symbol, style: fact.tint.style, text: "Pipeline \(fact.word)")
                        .font(.callout)
                }
                Spacer(minLength: 8)
                if let url = pipeline.url {
                    Button("Open Pipeline in GitLab") { actions.open(url) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            if !pipeline.stages.isEmpty {
                PillFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(pipeline.stages) { stage in
                        StageChip(stage: stage)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !listed.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(listed) { job in
                        JobRow(job: job) { actions.open($0) }
                    }
                }
                .padding(.horizontal, -6)
            }
            if attention.isEmpty, !jobs.isEmpty, !showsAll {
                Text(verbatim: Self.quietLine(jobs))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if jobs.count > Self.cut || (!attention.isEmpty && !rest.isEmpty) {
                Button(showsAll ? "Show Less" : "Show All (\(jobs.count))") {
                    withAnimation(.snappy) { showsAll.toggle() }
                }
                .buttonStyle(.link)
            }
        }
    }

    /// "All 12 jobs passed", or what the jobs are doing when nothing failed or runs
    private static func quietLine(_ jobs: [MergeRequestDetails.Job]) -> String {
        let waiting = jobs.filter { $0.state == .waiting }.count
        if jobs.allSatisfy({ $0.state == .passed || $0.state == .skipped }) {
            return jobs.count == 1 ? "The job passed" : "All \(jobs.count) jobs passed"
        }
        return waiting > 0 ? "\(waiting) \(waiting == 1 ? "job" : "jobs") waiting, none failed" : "None failed"
    }
}

/// A part's small heading inside a card: "Jenkins", "GitLab".
private struct SubHeading: View {
    let text: String

    var body: some View {
        Text(verbatim: text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

/// A stage as a small capsule: its state's symbol and its name.
private struct StageChip: View {
    let stage: MergeRequestDetails.Stage

    var body: some View {
        let state = stage.state
        HStack(spacing: 4) {
            Image(systemName: state.symbol)
                .foregroundStyle(state.color)
            Text(verbatim: stage.name)
        }
        .font(.subheadline)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(state.color.opacity(0.10), in: Capsule())
        .overlay { Capsule().strokeBorder(state.color.opacity(0.30), lineWidth: 0.5) }
        .accessibilityElement(children: .combine)
    }
}

/// A job: its state, its name and its stage; opens the job's page, and lights up on hover.
private struct JobRow: View {
    let job: MergeRequestDetails.Job
    let open: (URL) -> Void

    @ViewState private var isHovered = false

    var body: some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: job.state.symbol)
                .foregroundStyle(job.state.color)
            Text(verbatim: job.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(verbatim: job.stage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if job.url != nil {
                Image(systemName: "arrow.up.forward")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.fill.quaternary.opacity(isHovered ? 1 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(.rect)
        if let url = job.url {
            Button { open(url) } label: { content }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .help("Open the job in GitLab")
        } else {
            content
        }
    }
}

extension MergeRequestDetails.Job.State {
    /// the SF Symbol, round like the badges
    var symbol: String {
        switch self {
        case .failed: "xmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath.circle.fill"
        case .waiting: "clock.fill"
        case .passed: "checkmark.circle.fill"
        case .canceled: "stop.circle.fill"
        case .skipped: "minus.circle.fill"
        }
    }

    /// GitLab's colors: green passed, red failed, blue running, neutral for the rest
    var color: Color {
        switch self {
        case .failed: MergeRequestStatus.Color.red.swiftUI
        case .running: MergeRequestStatus.Color.blue.swiftUI
        case .passed: MergeRequestStatus.Color.green.swiftUI
        case .waiting: MergeRequestStatus.Color.orange.swiftUI
        case .canceled, .skipped: MergeRequestStatus.Color.neutral.swiftUI
        }
    }
}

// MARK: - Gallery

/// The details the gallery shows in place of the store's, by merge request reference.
struct MergeRequestDetailsFixtures: Sendable {
    var states: [String: MergeRequestDetailsState]
    /// what the stored token may do, as the token check would say
    var writeAccess: WriteAccess = .unknown
    /// what the Reviewers card shows of a re-request: the bulk question, the token explanation
    var reReviewPhase: ReReviewPhase?
    /// the code changes, by merge request reference (MR-11)
    var changes: [String: MergeRequestChangesState] = [:]
}

private struct MergeRequestDetailsFixturesKey: EnvironmentKey {
    static let defaultValue: MergeRequestDetailsFixtures? = nil
}

extension EnvironmentValues {
    /// the gallery's details; `nil` in the app, which takes the store's
    var mergeRequestDetailsFixtures: MergeRequestDetailsFixtures? {
        get { self[MergeRequestDetailsFixturesKey.self] }
        set { self[MergeRequestDetailsFixturesKey.self] = newValue }
    }
}
