import MenubarCore
import SwiftUI

/// What went, or goes, to Claude: the facts as sent, redacted, in a scrolling monospaced box that can be selected.
struct SentText: View {
    let prompt: ClaudePrompt

    var body: some View {
        ScrollView {
            Text(verbatim: prompt.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 220)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// One AI answer's rows in a detail's section, whatever its state (AI-02 to AI-04): a spinner while the facts are
/// gathered and while Claude answers ("Claude is thinking…" in both); the first time, what will be sent with Send to
/// Claude and Cancel; the answer, one layout everywhere: the model's name, the answer, then Ask Again With, the view's
/// own actions and Clear in one row, and what was sent; or the failure in plain words with Try Again. Below the answer
/// goes the conversation (AI-08): the follow-up questions and answers, and the field for the next one.
struct AIAnswerRows<Answer: View, Actions: View>: View {
    let state: AIAnswerState
    /// the subject the answer belongs to; with it the card offers "Ask Again With" another model
    var subject: AISubject?
    let send: () -> Void
    let dismiss: () -> Void
    /// the item the answer is about, for Continue in Claude Code with the conversation; `nil` offers none
    var item: ClaudeCodeContext?
    @ViewBuilder let answer: (AIAnswer) -> Answer
    /// more buttons in the answer's row, after Ask Again With, like "Continue in Claude Code"
    @ViewBuilder let actions: (AIAnswer) -> Actions

    @Environment(AppModel.self) private var model: AppModel?

    init(
        state: AIAnswerState, subject: AISubject? = nil, item: ClaudeCodeContext? = nil, send: @escaping () -> Void,
        dismiss: @escaping () -> Void, @ViewBuilder answer: @escaping (AIAnswer) -> Answer,
        @ViewBuilder actions: @escaping (AIAnswer) -> Actions
    ) {
        self.state = state
        self.subject = subject
        self.item = item
        self.send = send
        self.dismiss = dismiss
        self.answer = answer
        self.actions = actions
    }

    var body: some View {
        if let subject, model?.ai.stoppedSubjects.contains(subject) == true {
            VStack(alignment: .leading, spacing: 8) {
                Label("Stopped", systemImage: "stop.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                rows
            }
        } else {
            rows
        }
    }

    @ViewBuilder
    private var rows: some View {
        switch state {
        case .idle:
            EmptyView()
        case .preparing:
            progress
        case .review(let prompt):
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "This goes to Claude through your Claude Code login. Tokens, cookies and keys are removed. Once you "
                        + "send it, this kind of answer is sent without asking.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SentText(prompt: prompt)
                HStack(spacing: 8) {
                    Button("Send to Claude", action: send)
                        .buttonStyle(.borderedProminent)
                    Button("Cancel", action: dismiss)
                        .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                    Text(verbatim: "\(prompt.text.count.formatted()) characters")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        case .running:
            progress
        case .answered(let result):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(verbatim: result.modelName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Written by \(result.modelName)")
                    Spacer(minLength: 8)
                    // The Markdown answers take the description's reading size, ⌘+ and ⌘− too.
                    if result.text != nil || subject.map({ !(model?.ai.turns(of: $0).isEmpty ?? true) }) == true {
                        MarkdownSizeButtons()
                    }
                }
                answer(result)
                if let subject {
                    ConversationThread(subject: subject)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let subject {
                        AskAgainMenu(subject: subject, answered: ClaudeModel(rawValue: result.model))
                    }
                    actions(result)
                    if let subject, let item {
                        ContinueInClaudeCode(subject: subject, item: item)
                    }
                    Spacer(minLength: 8)
                    Button("Clear", action: dismiss)
                        .buttonStyle(.link)
                }
                .font(.callout)
                DisclosureGroup("What Was Sent") {
                    SentText(prompt: result.prompt)
                }
                .font(.callout)
            }
            .padding(.vertical, 2)
        case .failed(let message, let sent):
            StatusLine(.problem, message) {
                HStack(spacing: 10) {
                    if let subject, sent != nil {
                        Button("Try Again") {
                            Task { await model?.ai.askAgain(subject, model: model?.ai.settings.model ?? AISettings().model) }
                        }
                        .buttonStyle(.link)
                        AskAgainMenu(subject: subject)
                    }
                    Button("Dismiss", action: dismiss)
                        .buttonStyle(.link)
                }
            }
        }
    }

    /// the one loading state: a spinner, "Claude is thinking…" and Stop, which ends the run
    private var progress: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Claude is thinking…")
                .foregroundStyle(.secondary)
            if let subject {
                Spacer(minLength: 8)
                Button("Stop") { model?.ai.stop(subject) }
                    .buttonStyle(.link)
                    .font(.callout)
                    .help("Stop Claude")
            }
        }
    }
}

extension AIAnswerRows where Actions == EmptyView {
    init(
        state: AIAnswerState, subject: AISubject? = nil, item: ClaudeCodeContext? = nil, send: @escaping () -> Void,
        dismiss: @escaping () -> Void, @ViewBuilder answer: @escaping (AIAnswer) -> Answer
    ) {
        self.init(state: state, subject: subject, item: item, send: send, dismiss: dismiss, answer: answer) { _ in EmptyView() }
    }
}

extension AIAnswerState {
    /// whether the button that asks should wait: the facts are being gathered, or Claude answers
    var isBusy: Bool {
        switch self {
        case .preparing, .running: true
        default: false
        }
    }

    /// whether the section has rows to show under its button
    var hasRows: Bool {
        self != .idle
    }
}
