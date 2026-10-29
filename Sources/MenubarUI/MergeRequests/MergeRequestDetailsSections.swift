import MenubarCore
import SwiftUI

/// The merge request detail's GitLab sections (MR-06 to MR-08): Approvals, Unresolved Threads and the GitLab Pipeline.
///
/// They load when the merge request is selected, from `AppModel.mergeRequestDetails` or the gallery's
/// ``MergeRequestDetailsFixtures``, and are the one view `MergeRequestDetailsSections(mergeRequest:actions:)`. While
/// the details load, the Approvals section shows a placeholder row of the height of the real one, so little jumps; when
/// they fail, a quiet line with "Try Again". Read only: every row opens a page in the browser.
struct MergeRequestDetailsSections: View {
    let mergeRequest: MergeRequest
    let actions: GitLabSectionActions

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
        Section("Approvals") {
            ApprovalRows(state: state, retry: retry)
                .task(id: Ask(id: mergeRequest.id, updatedAt: mergeRequest.updatedAt)) { await load() }
        }
        if let details = state.details {
            ThreadsSection(details: details, mergeRequest: mergeRequest, actions: actions)
                .id(mergeRequest.id)
            if let pipeline = details.pipeline {
                PipelineSection(pipeline: pipeline, actions: actions)
                    .id(mergeRequest.id)
            }
        }
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

/// "1 of 2 approvals" with who approved, then the rules that need approvals, when GitLab has them.
private struct ApprovalRows: View {
    let state: MergeRequestDetailsState
    let retry: () -> Void

    var body: some View {
        if let details = state.details {
            let approvals = details.approvals
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: approvals.isSatisfied == true ? "checkmark.circle.fill" : "person.crop.circle.badge.clock")
                    .foregroundStyle(approvals.isSatisfied == true ? MergeRequestStatus.Color.green.swiftUI : MergeRequestStatus.Color.neutral.swiftUI)
                Text(verbatim: approvals.summary)
                    .textSelection(.enabled)
            }
            if !approvals.approvedBy.isEmpty {
                LabeledContent("Approved by") {
                    Text(verbatim: approvals.approvedBy.map(\.displayName).formatted(.list(type: .and, width: .narrow)))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            ForEach(approvals.rules.filter { $0.required > 0 }) { rule in
                RuleRow(rule: rule)
            }
        } else if state.failed {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("The details couldn't be loaded")
                    .foregroundStyle(.secondary)
                Button("Try Again", action: retry)
                    .buttonStyle(.link)
            }
        } else {
            // The height of the first real row, without shimmer and without a spinner over the pane (OD-01).
            Text(verbatim: "0 of 2 approvals")
                .redacted(reason: .placeholder)
        }
    }
}

/// An approval rule: its name and who approved under it, and whether it is satisfied.
private struct RuleRow: View {
    let rule: MergeRequestDetails.Rule

    var body: some View {
        LabeledContent {
            SymbolText(
                symbol: rule.isSatisfied ? "checkmark.circle.fill" : "circle.dotted",
                style: AnyShapeStyle(rule.isSatisfied ? MergeRequestStatus.Color.green.swiftUI : MergeRequestStatus.Color.neutral.swiftUI),
                text: "\(min(rule.approvedBy.count, rule.required)) of \(rule.required)")
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: rule.name)
                if !rule.approvedBy.isEmpty {
                    Text(verbatim: rule.approvedBy.map(\.displayName).formatted(.list(type: .and, width: .narrow)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension MergeRequest.Person {
    /// the name, else "@username" for a person without one
    var displayName: String {
        name.isEmpty ? "@\(username)" : name
    }
}

// MARK: - Threads

/// The threads that can be resolved and aren't: who started each, the file and line of a diff note and the start of the
/// note, each opening the note. Cut after 5 with "Show All (N)"; with none open, a quiet line when some were resolved.
private struct ThreadsSection: View {
    let details: MergeRequestDetails
    let mergeRequest: MergeRequest
    let actions: GitLabSectionActions

    @ViewState private var showsAll = false

    private static let cut = 5

    var body: some View {
        let threads = details.threads
        if threads.isEmpty {
            if details.resolvedThreadCount > 0 {
                Section("Threads") {
                    SymbolText(
                        symbol: "checkmark.circle.fill", style: AnyShapeStyle(MergeRequestStatus.Color.green.swiftUI),
                        text: details.resolvedThreadCount == 1 ? "The thread is resolved" : "All \(details.resolvedThreadCount) threads are resolved")
                }
            }
        } else {
            Section("Unresolved Threads (\(threads.count)\(details.hasMoreDiscussions ? "+" : ""))") {
                ForEach(showsAll ? threads : Array(threads.prefix(Self.cut))) { thread in
                    ThreadRow(thread: thread) { actions.open($0) }
                }
                if threads.count > Self.cut {
                    Button(showsAll ? "Show Less" : "Show All (\(threads.count))") {
                        withAnimation(.snappy) { showsAll.toggle() }
                    }
                    .buttonStyle(.link)
                }
                if details.hasMoreDiscussions {
                    Button("More Threads in GitLab") { actions.open(mergeRequest.webURL) }
                        .buttonStyle(.link)
                }
            }
        }
    }
}

private struct ThreadRow: View {
    let thread: MergeRequestDetails.ReviewThread
    let open: (URL) -> Void

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: thread.author?.displayName ?? "Someone")
                    .fontWeight(.medium)
                if let location = thread.location {
                    Text(verbatim: location)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if !thread.excerpt.isEmpty {
                Text(verbatim: thread.excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        if let url = thread.url {
            Button { open(url) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    content
                    Image(systemName: "arrow.up.forward")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .help("Open the thread in GitLab")
        } else {
            content
        }
    }
}

// MARK: - The pipeline

/// The head pipeline: its status, its stages as small chips, and the failed and running jobs, each opening its page.
private struct PipelineSection: View {
    let pipeline: MergeRequestDetails.Pipeline
    let actions: GitLabSectionActions

    @ViewState private var showsAll = false

    private static let cut = 5

    var body: some View {
        let jobs = pipeline.jobs
        let attention = pipeline.needAttention
        let rest = jobs.filter { job in !attention.contains(where: { $0.id == job.id }) }
        let listed = showsAll ? attention + rest : Array(attention.prefix(Self.cut))
        Section("GitLab Pipeline") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let status = pipeline.status {
                    let fact = MergeRequestDetailModel.PipelineFact(status)
                    SymbolText(symbol: fact.symbol, style: fact.tint.style, text: "Pipeline \(fact.word)")
                } else {
                    Text("Pipeline")
                }
                Spacer(minLength: 8)
                if let url = pipeline.url {
                    Button("Open Pipeline") { actions.open(url) }
                        .buttonStyle(.link)
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
            ForEach(listed) { job in
                JobRow(job: job) { actions.open($0) }
            }
            if attention.isEmpty, !jobs.isEmpty, !showsAll {
                Text(verbatim: Self.quietLine(jobs))
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

/// A job: its state, its name and its stage; opens the job's page.
private struct JobRow: View {
    let job: MergeRequestDetails.Job
    let open: (URL) -> Void

    var body: some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: job.state.symbol)
                .foregroundStyle(job.state.color)
            Text(verbatim: job.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(verbatim: job.stage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if job.url != nil {
                Image(systemName: "arrow.up.forward")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
        if let url = job.url {
            Button { open(url) } label: { content }
                .buttonStyle(.plain)
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
    /// what the Reviewers section shows of a re-request: the bulk question, the token explanation
    var reReviewPhase: ReReviewPhase?
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
