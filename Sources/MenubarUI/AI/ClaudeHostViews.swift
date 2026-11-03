import AppKit
import MenubarCore
import SwiftUI

// MARK: - The turn in progress

/// A hosted chat's turn while Claude Code works (AI-10): each tool call as a quiet line, the text as it streams, then
/// what waits for the developer, a tool call to allow or a question to answer, and Stop while nothing waits.
struct HostLiveTurn: View {
    let turn: ClaudeHostTurn
    let subject: AISubject
    /// Stop: Claude ends the turn and the question comes back
    let stop: () -> Void

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !turn.steps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(turn.steps) { step in
                        HostStepLine(step: step)
                    }
                }
            }
            if !turn.text.isEmpty {
                MarkdownView(markdown: turn.text, base: nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(turn.pending) { request in
                if request.isQuestion {
                    HostQuestionCard(request: request) { model?.ai.answer(request, of: subject, with: $0) }
                } else {
                    HostPermissionCard(request: request) { model?.ai.answer(request, of: subject, with: $0) }
                }
            }
            HStack(spacing: 8) {
                if turn.pending.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                    Text(turn.steps.isEmpty && turn.text.isEmpty ? "Claude is thinking…" : "Claude is working…")
                        .foregroundStyle(.secondary)
                } else {
                    Text(turn.pending.count == 1 ? "Claude waits for you" : "Claude waits for \(turn.pending.count) answers")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Stop", action: stop)
                    .buttonStyle(.link)
                    .font(.callout)
                    .help("Stop Claude: it ends this turn and keeps the chat")
            }
        }
    }
}

/// One tool call: a small status mark, the tool's name, and what it does in monospace.
struct HostStepLine: View {
    let step: ClaudeHostStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                switch step.status {
                case .running:
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(.secondary)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption)
            Text(verbatim: ClaudeHostTool.title(of: step.toolName))
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            if !step.summary.isEmpty {
                Text(verbatim: step.summary)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.callout)
        .help(step.summary)
    }
}

// MARK: - A tool call to allow

/// A tool call that waits for the developer: the tool, what it does (the command, the file, the MCP tool), the full
/// input in a disclosure, and Allow, Always for This Chat (only when Claude Code suggests a rule), Deny.
struct HostPermissionCard: View {
    let request: ClaudeHostRequest
    let answer: (ClaudePermissionChoice) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text("Claude wants to use \(Text(verbatim: ClaudeHostTool.title(of: request.displayName)).fontWeight(.semibold))")
            }
            if !request.summary.isEmpty {
                Text(verbatim: request.summary)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            DisclosureGroup("Details") {
                ScrollView {
                    Text(verbatim: request.input.prettyText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 180)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            .font(.callout)
            HStack(spacing: 8) {
                Button("Allow") { answer(.allowOnce) }
                    .buttonStyle(.borderedProminent)
                    .help("Allow this call once")
                if request.offersAlways {
                    Button("Always for This Chat") { answer(.allowAlways) }
                        .buttonStyle(.bordered)
                        .help("Allow calls like this until the chat ends; nothing is saved to your settings")
                }
                Button("Deny") { answer(.deny("The developer denied this in MegaMonitor.")) }
                    .buttonStyle(.bordered)
                    .help("Refuse it; Claude is told and goes on")
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(colorScheme == .dark ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
        }
    }
}

// MARK: - A question to answer

/// Claude's questions (`AskUserQuestion`): each with its header as a chip and its options as buttons, their
/// descriptions as help; a multiple choice takes toggles and Send, and "Other…" takes a free answer.
struct HostQuestionCard: View {
    let request: ClaudeHostRequest
    let answer: (ClaudePermissionChoice) -> Void

    /// the picked labels, by question
    @ViewState private var picked: [String: Set<String>] = [:]
    /// the free answers, by question
    @ViewState private var other: [String: String] = [:]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(request.questions) { question in
                questionView(question)
            }
            if !answersAtOnce {
                HStack {
                    Button("Send Answers") { send() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isComplete)
                    Button("Skip") { answer(.deny("The developer skipped the question.")) }
                        .buttonStyle(.link)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.purple.opacity(colorScheme == .dark ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.35), lineWidth: 1)
        }
    }

    /// a single question with single choice answers with one click
    private var answersAtOnce: Bool {
        request.questions.count == 1 && request.questions.first?.multiSelect == false
    }

    private var isComplete: Bool {
        request.questions.allSatisfy { answerText(for: $0) != nil }
    }

    private func answerText(for question: ClaudeHostQuestion) -> String? {
        let free = (other[question.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !free.isEmpty {
            return free
        }
        let labels = question.options.map(\.label).filter { picked[question.question]?.contains($0) == true }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    private func send() {
        var answers: [String: String] = [:]
        for question in request.questions {
            if let text = answerText(for: question) {
                answers[question.question] = text
            }
        }
        answer(.answers(answers))
    }

    @ViewBuilder
    private func questionView(_ question: ClaudeHostQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(.purple)
                if !question.header.isEmpty {
                    Text(verbatim: question.header)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.purple.opacity(0.18), in: Capsule())
                }
            }
            Text(verbatim: question.question)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(question.options, id: \.label) { option in
                    optionButton(option, of: question)
                }
            }
            HStack(spacing: 6) {
                TextField("Other…", text: binding(for: question))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if answersAtOnce, let text = answerText(for: question) {
                            answer(.answers([question.question: text]))
                        }
                    }
                if answersAtOnce {
                    Button("Send") {
                        if let text = answerText(for: question) {
                            answer(.answers([question.question: text]))
                        }
                    }
                    .disabled((other[question.question] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func optionButton(_ option: ClaudeHostQuestion.Option, of question: ClaudeHostQuestion) -> some View {
        let isPicked = picked[question.question]?.contains(option.label) == true
        Button {
            if answersAtOnce {
                answer(.answers([question.question: option.label]))
            } else if question.multiSelect {
                var labels = picked[question.question] ?? []
                if isPicked { labels.remove(option.label) } else { labels.insert(option.label) }
                picked[question.question] = labels
            } else {
                picked[question.question] = [option.label]
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !answersAtOnce {
                    Image(systemName: question.multiSelect
                        ? (isPicked ? "checkmark.square.fill" : "square")
                        : (isPicked ? "largecircle.fill.circle" : "circle"))
                        .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: option.label)
                        .fontWeight(.medium)
                    if !option.description.isEmpty {
                        Text(verbatim: option.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isPicked ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.background.opacity(0.6)),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .help(option.description)
    }

    private func binding(for question: ClaudeHostQuestion) -> Binding<String> {
        Binding(
            get: { other[question.question] ?? "" },
            set: { other[question.question] = $0 })
    }
}

// MARK: - Raw Response

/// "Raw Response": the answer's Markdown source as plain selectable text, and the run's facts (model, duration, tool
/// calls, how it ended, stderr's last lines), with Copy. Never a cost.
struct RawResponseDisclosure: View {
    let raw: ClaudeRawResponse

    var body: some View {
        DisclosureGroup("Raw Response") {
            RawResponseContent(raw: raw)
        }
        .font(.callout)
    }
}

/// The inside of ``RawResponseDisclosure``.
struct RawResponseContent: View {
    let raw: ClaudeRawResponse

    @ViewState private var copied = false

    var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                    if let model = raw.model {
                        fact("Model", model)
                    }
                    if let duration = raw.durationMS {
                        fact("Duration", ClaudeRawResponse.seconds(duration))
                    }
                    fact("Outcome", raw.outcome)
                    if let status = raw.exitStatus {
                        fact("Exit Status", "\(status)")
                    }
                    if !raw.toolCalls.isEmpty {
                        fact("Tool Calls", raw.toolCalls.joined(separator: "\n"))
                    }
                }
                .font(.callout)
                box(raw.markdown)
                if let stderr = raw.stderrTail, !stderr.isEmpty {
                    Text("stderr")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    box(stderr)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(raw.asText, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the facts and the Markdown source")
            }
            .padding(.top, 4)
            .font(.callout)
    }

    @ViewBuilder
    private func fact(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func box(_ text: String) -> some View {
        let content = Text(verbatim: text.isEmpty ? " " : text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        // As tall as a short text; a long one scrolls.
        let isShort = text.count < 1_200 && text.split(separator: "\n", omittingEmptySubsequences: false).count <= 14
        return Group {
            if isShort {
                content.fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView { content }
                    .frame(height: 220)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
