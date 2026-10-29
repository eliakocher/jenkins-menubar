import MenubarCore
import SwiftUI

/// The failed build detail's Claude section (AI-02, AI-05): "Why Did It Fail?" with Claude's card, the likely cause,
/// the fix and real or flaky, and "Open in Claude Code". Hidden while the Claude features are off or `claude` isn't
/// installed, and in the gallery.
struct ExplainBuildSection: View {
    let build: Build
    /// the build's page, which Claude Code's prompt links
    let page: URL?

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model, model.ai.isOffered {
            let subject = AISubject.build(build.id)
            let state = model.ai.state(of: subject)
            let failedTests: [FailedTest]? =
                if case .loaded(let tests) = model.failedTests.state(of: build.id) { tests } else { nil }
            Section {
                HStack(spacing: 8) {
                    Button("Why Did It Fail?") {
                        Task { await model.ai.explain(build, failedTests: failedTests) }
                    }
                    .disabled(state.isBusy)
                    .help("Ask Claude for the likely cause and a fix, from the end of the log, the failed tests and the changes")
                    OpenInClaudeCodeButton(context: .build(build, page: page, failedTests: failedTests ?? []))
                }
                .buttonStyle(.bordered)
                ClaudeCodeLaunchLine(context: .build(build, page: page, failedTests: []))
                AIAnswerRows(
                    state: state, send: { Task { await model.ai.send(subject) } }, dismiss: { model.ai.dismiss(subject) }
                ) { answer in
                    if let explanation = answer.explanation {
                        BuildExplanationCard(explanation: explanation)
                    }
                }
            } header: {
                Text("Claude")
            }
        }
    }
}

/// Claude's card for a failed build: the verdict as a badge, then the cause and the fix.
struct BuildExplanationCard: View {
    let explanation: BuildExplanation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusBadge(text: explanation.verdict.title, symbol: symbol, tint: tint)
            labeled("Likely cause", explanation.cause)
            labeled("Fix", explanation.fix)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch explanation.verdict {
        case .real: "xmark.octagon"
        case .flaky: "arrow.triangle.2.circlepath"
        case .unclear: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch explanation.verdict {
        case .real: .red
        case .flaky: .orange
        case .unclear: .secondary
        }
    }

    private func labeled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The merge request detail's Claude section, right after its threads (AI-03, AI-05): "Summarize Discussion" with
/// what was agreed, what is open and who it waits on, and "Open in Claude Code".
struct ThreadsSummarySection: View {
    let mergeRequest: MergeRequest

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model, model.ai.isOffered {
            let subject = AISubject.mergeRequest(mergeRequest.reference)
            let state = model.ai.state(of: subject)
            Section {
                HStack(spacing: 8) {
                    Button("Summarize Discussion") {
                        Task { await model.ai.summarize(mergeRequest) }
                    }
                    .disabled(state.isBusy)
                    .help("Ask Claude what the review threads agreed, what is open and who it waits on")
                    OpenInClaudeCodeButton(context: .mergeRequest(mergeRequest))
                }
                .buttonStyle(.bordered)
                ClaudeCodeLaunchLine(context: .mergeRequest(mergeRequest))
                AIAnswerRows(
                    state: state, send: { Task { await model.ai.send(subject) } }, dismiss: { model.ai.dismiss(subject) }
                ) { answer in
                    if let summary = answer.summary {
                        ThreadsSummaryCard(summary: summary)
                    }
                }
            } header: {
                Text("Claude")
            }
        }
    }
}

/// Claude's summary of a discussion: the open points with whom they wait on, then what was agreed.
struct ThreadsSummaryCard: View {
    let summary: ThreadsSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !summary.open.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(summary.open.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "circle")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: point.point)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(verbatim: "Waiting on \(point.waitingOn)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !summary.agreed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agreed")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(summary.agreed.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text(verbatim: point)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if summary.open.isEmpty && summary.agreed.isEmpty {
                Text("Nothing to summarize")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The work item detail's Claude section (AI-05): "Open in Claude Code" in the checkout on the item's branch.
struct ClaudeWorkItemSection: View {
    let workItem: WorkItem

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model, model.ai.isOffered, !workItem.isEpic {
            Section {
                OpenInClaudeCodeButton(context: .workItem(workItem))
                ClaudeCodeLaunchLine(context: .workItem(workItem))
            } header: {
                Text("Claude")
            } footer: {
                Text("Starts Claude Code in the checkout on this item's branch, with the item as its first prompt.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
