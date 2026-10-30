import MenubarCore
import SwiftUI

/// The failed build detail's Claude section (AI-02, AI-05): one row with "Why Did It Fail?" as its primary action and
/// "Open in Claude Code" next to it, and Claude's investigation as a card below. Hidden while the Claude features are
/// off or `claude` isn't installed, and in the gallery.
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
            let hints: [FlakyHint] =
                if case .loaded(let hints) = model.flakyHints.state(of: build.id) { hints } else { [] }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            buttons(model, state: state, failedTests: failedTests, hints: hints)
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            buttons(model, state: state, failedTests: failedTests, hints: hints)
                        }
                    }
                    if state == .idle {
                        Text("Claude reads the failed tests, the errors in the log and the commits since the last green build.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
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

    @ViewBuilder
    private func buttons(_ model: AppModel, state: AIAnswerState, failedTests: [FailedTest]?, hints: [FlakyHint]) -> some View {
        Button {
            Task { await model.ai.explain(build, failedTests: failedTests, flakyHints: hints) }
        } label: {
            Label("Why Did It Fail?", systemImage: "sparkles")
        }
        .buttonStyle(.borderedProminent)
        .disabled(state.isBusy)
        .help("Ask Claude for the root cause, the evidence in the log, the suspect commits and the next step")
        OpenInClaudeCodeButton(context: .build(build, page: page, failedTests: failedTests ?? []))
    }
}

/// Claude's investigation of a failed build (AI-02), in the order a developer reads it: the verdict, the diagnosis and
/// where it failed; the root cause; the evidence lines from the log in monospace, collapsible; the suspect commits; the
/// next step.
struct BuildExplanationCard: View {
    let explanation: BuildExplanation

    @ViewState private var showsEvidence = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                StatusBadge(text: explanation.verdict.title, symbol: symbol, tint: tint)
                if !explanation.headline.isEmpty {
                    Text(verbatim: explanation.headline)
                        .font(.headline)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !explanation.failedAt.isEmpty {
                    Label {
                        Text(verbatim: explanation.failedAt)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "mappin.and.ellipse")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            part("Root Cause") {
                Text(verbatim: explanation.cause)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !explanation.evidence.isEmpty {
                DisclosureGroup(isExpanded: $showsEvidence) {
                    evidence
                        .padding(.top, 4)
                } label: {
                    heading(explanation.evidence.count == 1 ? "Evidence" : "Evidence (\(explanation.evidence.count) lines)")
                }
            }
            if !explanation.suspects.isEmpty {
                part("Suspect Commits") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(explanation.suspects.enumerated()), id: \.offset) { _, suspect in
                            SuspectRow(suspect: suspect)
                        }
                    }
                }
            }
            if !explanation.nextStep.isEmpty {
                part("Next Step") {
                    Label {
                        Text(verbatim: explanation.nextStep)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "arrow.forward.circle")
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The evidence lines as they are in the log: monospaced, one per line, in a quiet box that scrolls sideways.
    private var evidence: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(explanation.evidence.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private var symbol: String {
        switch explanation.verdict {
        case .real: "xmark.octagon"
        case .flaky: "arrow.triangle.2.circlepath"
        case .infrastructure: "server.rack"
        case .unclear: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch explanation.verdict {
        case .real: .red
        case .flaky: .orange
        case .infrastructure: .blue
        case .unclear: .secondary
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func part(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            heading(title)
            content()
        }
    }
}

/// A suspect commit: its short hash in monospace, the message, and the author with why it is suspect.
private struct SuspectRow: View {
    let suspect: BuildExplanation.Suspect

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: String(suspect.commit.prefix(8)))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: suspect.message.isEmpty ? suspect.commit : suspect.message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                let byline = [suspect.author, suspect.why].filter { !$0.isEmpty }.joined(separator: " · ")
                if !byline.isEmpty {
                    Text(verbatim: byline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
