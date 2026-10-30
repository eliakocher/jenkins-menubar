import MenubarCore
import SwiftUI

// MARK: - The chat

/// An inline chat with Claude in a card (AI-07, AI-08): a multi-line field (⌘↩) with the model as a menu, quick-pick
/// buttons above it that fill the question, then, once asked, the question as a bubble and Claude's answers and
/// follow-ups as the conversation thread: Markdown at the reading size, Copy, Stop, Clear and Continue in Claude Code.
/// The work item's card and the merge request's card both use it.
///
/// The first question starts the subject's answer (it shows what it sends the first time); later ones are follow-ups.
/// A scope chip, when there is a scope, shows in the field and as a small chip on each question.
struct InlineClaudeChat<Footer: View>: View {
    /// what the conversation is kept under
    let subject: AISubject
    /// the item the chat is about, for Continue in Claude Code
    let item: ClaudeCodeContext
    /// the link relative links in the answers resolve against
    var base: URL?
    /// the field's placeholder before the first question
    var placeholder = "Ask Claude…"
    /// the placeholder of the field under an answer
    var followUpPlaceholder = "Ask a follow-up…"
    /// buttons above the field that fill the question: a title and the words
    var quickPicks: [(title: String, question: String)] = []
    /// what the next question is about; `nil` shows no chip
    var scope: CodeScope?
    var clearScope: () -> Void = {}
    /// changes when the field should take the focus
    var focusCount = 0
    /// the checkout whose own `.claude` commands the "/" list adds; `nil` for none
    var commandsFolder: String?
    /// asks the first question with the model picked for it; `nil` is Settings' model
    let ask: (String, ClaudeModel?) -> Void
    /// asks a follow-up; `nil` asks it with the conversation's own rules (no scope)
    var followUp: ((String, ClaudeModel?) -> Void)?
    /// more rows under the chat, told where the answer stands
    @ViewBuilder let footer: (AIAnswerState) -> Footer

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model {
            let state = model.ai.state(of: subject)
            VStack(alignment: .leading, spacing: 10) {
                if state == .idle {
                    ClaudeComposer(
                        placeholder: placeholder, quickPicks: quickPicks, scope: scope, clearScope: clearScope,
                        focusCount: focusCount, commandsFolder: commandsFolder, isThinking: false, send: ask, stop: { nil },
                        // A stopped question comes back, to be sent again or changed.
                        restore: { model.ai.takeStoppedQuestion(of: subject) })
                } else if let question = model.ai.openingQuestions[subject] {
                    QuestionBubble(question: question, scope: model.ai.openingScopes[subject])
                }
                AIAnswerRows(
                    state: state, subject: subject, item: item,
                    send: { Task { await model.ai.send(subject) } }, dismiss: { model.ai.dismiss(subject) }
                ) { answer in
                    if let text = answer.text {
                        MarkdownView(document: MarkdownDocument(parsing: text, base: base))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                footer(state)
            }
            .environment(
                \.claudeChat,
                ClaudeChatOptions(
                    placeholder: followUpPlaceholder, quickPicks: quickPicks, scope: scope, clearScope: clearScope,
                    focusCount: focusCount, commandsFolder: commandsFolder, followUp: followUp))
        }
    }
}

extension InlineClaudeChat where Footer == EmptyView {
    init(
        subject: AISubject, item: ClaudeCodeContext, base: URL? = nil, placeholder: String = "Ask Claude…",
        followUpPlaceholder: String = "Ask a follow-up…", quickPicks: [(title: String, question: String)] = [],
        scope: CodeScope? = nil, clearScope: @escaping () -> Void = {}, focusCount: Int = 0, commandsFolder: String? = nil,
        ask: @escaping (String, ClaudeModel?) -> Void, followUp: ((String, ClaudeModel?) -> Void)? = nil
    ) {
        self.init(
            subject: subject, item: item, base: base, placeholder: placeholder, followUpPlaceholder: followUpPlaceholder,
            quickPicks: quickPicks, scope: scope, clearScope: clearScope, focusCount: focusCount,
            commandsFolder: commandsFolder, ask: ask,
            followUp: followUp
        ) { _ in EmptyView() }
    }
}

/// What the field under an answer needs from the chat it is in: its placeholder, quick picks, scope chip and how a
/// follow-up goes. Set by ``InlineClaudeChat``; read by the conversation thread.
struct ClaudeChatOptions: @unchecked Sendable {
    var placeholder = "Ask a follow-up…"
    var quickPicks: [(title: String, question: String)] = []
    var scope: CodeScope?
    var clearScope: () -> Void = {}
    var focusCount = 0
    var commandsFolder: String?
    var followUp: ((String, ClaudeModel?) -> Void)?
}

private struct ClaudeChatKey: EnvironmentKey {
    static let defaultValue: ClaudeChatOptions? = nil
}

extension EnvironmentValues {
    /// the chat the views inside belong to, `nil` outside an ``InlineClaudeChat``
    var claudeChat: ClaudeChatOptions? {
        get { self[ClaudeChatKey.self] }
        set { self[ClaudeChatKey.self] = newValue }
    }
}

// MARK: - A question

/// A question as a quiet bubble on the right, with a small chip above it when it is about lines or a file.
struct QuestionBubble: View {
    let question: String
    /// what the question is about; the whole merge request and `nil` show no chip
    var scope: CodeScope?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let scope, scope != .mergeRequest {
                ScopeChip(scope: scope)
            }
            Text(verbatim: question)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
    }
}

/// What a question is about, as a quiet chip: a symbol, then the lines and the path in monospace; with `onClear`, an ✕
/// takes it off.
struct ScopeChip: View {
    let scope: CodeScope
    var onClear: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            switch scope {
            case .lines(let selection, let span):
                Text("\(Text(verbatim: span.title.capitalizedFirst).fontWeight(.medium)) of \(Text(verbatim: selection.path).font(.system(.callout, design: .monospaced)))")
            case .file(let path):
                Text(verbatim: path)
                    .font(.system(.callout, design: .monospaced))
            case .mergeRequest:
                Text("The whole merge request")
                    .fontWeight(.medium)
            }
            if let onClear {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Ask about the whole merge request instead")
                .accessibilityLabel("Remove the scope")
            }
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.head)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(scope.title)
    }

    private var symbol: String {
        switch scope {
        case .lines: "text.line.first.and.arrowtriangle.forward"
        case .file: "doc.text"
        case .mergeRequest: "arrow.triangle.pull"
        }
    }
}

extension String {
    /// the text with its first letter capitalized: "Lines 12–30"
    fileprivate var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
