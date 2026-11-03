import MenubarCore
import SwiftUI

/// The build detail's Claude card (AI-02, AI-05, AI-10): always there while the Claude features are on, for a build of any
/// result. On top, on a failed or unstable build, "Why Did It Fail?" as a quick action with Claude's investigation below
/// it; then the chat, a field for a free question ("Ask about this build…") scoped to the build: its stages, failed
/// tests, the log's errors and its end, and the changes since the last green build. The chat's own "Continue in Claude
/// Code" takes either on from there. Hidden while the Claude features are off or `claude` isn't installed, and in the
/// gallery.
///
/// The investigation and the chat are two subjects (``AISubject/build(_:)``, ``AISubject/buildChat(_:)``). The
/// investigation's answer has its own follow-up field, so the chat's field waits while the investigation is on the card
/// and the chat has nothing yet: one field at a time.
struct BuildClaudeCard: View {
    let build: Build
    /// the build's page, which Claude Code's prompt links
    let page: URL?
    /// whether "Why Did It Fail?" shows: for a failed or unstable build
    let offersWhy: Bool

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model, model.ai.isOffered {
            let why = AISubject.build(build.id)
            let chat = AISubject.buildChat(build.id)
            let whyState = model.ai.state(of: why)
            let failedTests: [FailedTest]? =
                if case .loaded(let tests) = model.failedTests.state(of: build.id) { tests } else { nil }
            let hints: [FlakyHint] =
                if case .loaded(let hints) = model.flakyHints.state(of: build.id) { hints } else { [] }
            let context = ClaudeCodeContext.build(build, page: page, failedTests: failedTests ?? [])
            DetailCard("Claude", symbol: "sparkles", width: .fullWidth) {
                VStack(alignment: .leading, spacing: 12) {
                    if offersWhy {
                        explanation(model, state: whyState, failedTests: failedTests, hints: hints, context: context)
                    }
                    if !whyState.hasRows || model.ai.state(of: chat).hasRows {
                        InlineClaudeChat(
                            subject: chat, item: context, placeholder: "Ask about this build…",
                            followUpPlaceholder: "Ask about this build…", quickPicks: quickPicks,
                            ask: { question, picked in
                                Task {
                                    await model.ai.ask(
                                        question, aboutBuild: build, failedTests: failedTests, flakyHints: hints, model: picked)
                                }
                            }
                        ) { state in
                            if state == .idle {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(
                                        "Claude gets the stages, the failed tests, the errors in the log and its end, and the changes since the last green build."
                                    )
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    // The Claude features are turned on and off in Settings → Claude.
                                    SettingsGearButton(field: .claude)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// the quick questions above the field: for every build, and one more for a red one
    private var quickPicks: [(title: String, question: String)] {
        var picks = [
            (
                title: "Summarize Build",
                question: "Summarize this build in a few lines: what ran, how long it took, and anything that stands out."
            ),
            (
                title: "What Changed?",
                question: "Which commits came into this build since the last green build, and which of them could matter most?"
            ),
        ]
        if offersWhy {
            picks.append(
                (
                    title: "Is It Flaky?",
                    question: "Does the failure look flaky? Say why or why not, from the log and the stages' history."
                ))
        }
        return picks
    }

    /// "Why Did It Fail?" and Claude's investigation below it
    @ViewBuilder
    private func explanation(
        _ model: AppModel, state: AIAnswerState, failedTests: [FailedTest]?, hints: [FlakyHint], context: ClaudeCodeContext
    ) -> some View {
        let subject = AISubject.build(build.id)
        VStack(alignment: .leading, spacing: 8) {
            ClaudeActionButton(
                title: "Why Did It Fail?", systemImage: "sparkles", prominent: true,
                help: "Ask Claude for the root cause, the evidence in the log, the suspect commits and the next step.",
                isDisabled: state.isBusy
            ) { picked in
                Task { await model.ai.explain(build, failedTests: failedTests, flakyHints: hints, model: picked) }
            }
            .controlSize(.small)
            AIAnswerRows(
                state: state, subject: subject, item: context,
                send: { Task { await model.ai.send(subject) } }, dismiss: { model.ai.dismiss(subject) }
            ) { answer in
                if let explanation = answer.explanation {
                    BuildExplanationCard(explanation: explanation)
                }
            }
        }
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
