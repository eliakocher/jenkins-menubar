import AppKit
import MenubarCore
import SwiftUI

/// The conversation below a Claude answer (AI-08): the follow-up questions in quiet bubbles, Claude's answers as
/// Markdown at the shared reading size, and the follow-up field at the bottom. It follows the first answer in every
/// Claude card; the first answer itself stays what it was, a card or Markdown.
struct ConversationThread: View {
    let subject: AISubject

    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.claudeChat) private var chat

    var body: some View {
        if let model {
            let turns = model.ai.turns(of: subject)
            VStack(alignment: .leading, spacing: 14) {
                if !turns.isEmpty {
                    ForEach(turns) { turn in
                        TurnView(turn: turn, subject: subject)
                    }
                }
                ClaudeComposer(
                    placeholder: chat?.placeholder ?? "Ask a follow-up…",
                    quickPicks: chat?.quickPicks ?? [], scope: chat?.scope, clearScope: chat?.clearScope ?? {},
                    focusCount: chat?.focusCount ?? 0, commandsFolder: chat?.commandsFolder,
                    isThinking: turns.contains { $0.status == .thinking },
                    send: { question, picked in
                        if let followUp = chat?.followUp {
                            followUp(question, picked)
                        } else {
                            Task { await model.ai.followUp(subject, question: question, model: picked) }
                        }
                    },
                    stop: { model.ai.stopFollowUp(of: subject) })
                .id(Self.endID)
            }
        }
    }

    /// the thread's end, for a scroll view that follows it
    static let endID = "claude-thread-end"
}

/// One turn: the question as a quiet bubble on the right, then Claude's answer, "Claude is thinking…" with Stop, or the
/// failure with Try Again.
private struct TurnView: View {
    let turn: ConversationTurn
    let subject: AISubject

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuestionBubble(question: turn.question, scope: turn.scope)
            switch turn.status {
            case .thinking:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Claude is thinking…")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Stop") { model?.ai.stopFollowUp(of: subject) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            case .answered(let text, _, _):
                ClaudeReply(text: text, modelName: turn.modelName)
            case .failed(let message):
                StatusLine(.problem, message) {
                    HStack(spacing: 10) {
                        Button("Try Again") {
                            Task { await model?.ai.retry(turn, of: subject) }
                        }
                        .buttonStyle(.link)
                        Button("Dismiss") { model?.ai.remove(turn, of: subject) }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }
}

/// Claude's answer to a follow-up: a purple sparkle with the model's name and Copy, then the Markdown, which can be
/// selected.
private struct ClaudeReply: View {
    let text: String
    let modelName: String?

    @ViewState private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownView(document: MarkdownDocument(parsing: text, base: nil))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                if let modelName {
                    Text(verbatim: modelName)
                        .accessibilityLabel("Written by \(modelName)")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .help("Copy this answer as Markdown")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// The follow-up field: a rounded box that grows with the text up to eight lines, "Ask a follow-up…" as its
/// placeholder, the model of the next question as a menu with names only, and a send button (⌘↩), which is Stop while
/// Claude answers; stopping puts the question back in the field.
struct ClaudeComposer: View {
    var placeholder = "Ask a follow-up…"
    /// buttons above the box that fill the question: a title and the words
    var quickPicks: [(title: String, question: String)] = []
    /// what the question is about, as a removable chip in the box; `nil` shows none
    var scope: CodeScope?
    var clearScope: () -> Void = {}
    /// changes when the field should take the focus
    var focusCount = 0
    /// the checkout whose own `.claude` commands the "/" list adds; `nil` for none
    var commandsFolder: String?
    var isThinking: Bool
    /// sends the question with the model picked for it; `nil` is Settings' model
    let send: (String, ClaudeModel?) -> Void
    /// stops the answer in progress; returns its question
    let stop: () -> String?
    /// a question to take into the field when it appears, like a stopped first one
    var restore: () -> String? = { nil }

    @Environment(AppModel.self) private var model: AppModel?
    @Environment(WindowRouter.self) private var router: WindowRouter?
    @ViewState private var text = ""
    @ViewState private var picked: ClaudeModel?
    /// the row of the "/" list Return inserts
    @ViewState private var highlighted = 0
    /// the text Escape closed the "/" list for
    @ViewState private var dismissedText: String?
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let defaultModel = model?.ai.settings.model ?? AISettings().model
        let current = picked ?? defaultModel
        VStack(alignment: .leading, spacing: 8) {
            if !quickPicks.isEmpty {
                HStack(spacing: 6) {
                    ForEach(quickPicks, id: \.title) { pick in
                        Button(pick.title) {
                            text = pick.question
                            isFocused = true
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                    }
                }
            }
            slashList
            box(current: current)
        }
        .onChange(of: focusCount) { isFocused = true }
        .onChange(of: text) { highlighted = 0 }
        // The commands are read when the "/" list is first wanted, not before.
        .task(id: slashQuery == nil ? nil : commandsFolder ?? "") {
            if slashQuery != nil, model?.ai.settings.useMySetup == true {
                await model?.ai.loadSlashCommands(project: commandsFolder)
            }
        }
        .onAppear {
            if text.isEmpty, let question = restore() {
                text = question
            }
        }
    }

    private func box(current: ClaudeModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let scope {
                ScopeChip(scope: scope, onClear: clearScope)
            }
            // The hidden text sizes the box; the editor fills it.
            Text(verbatim: text.isEmpty ? " " : text + "\u{200B}")
                .lineLimit(1...8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .opacity(0)
                .overlay {
                    TextEditor(text: $text)
                        .scrollContentBackground(.hidden)
                        .focused($isFocused)
                        .onKeyPress(keys: [.upArrow, .downArrow, .return, .tab, .escape], action: slashKey)
                        .padding(.vertical, -2)
                }
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(verbatim: placeholder)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                Menu {
                    Section("Ask With") {
                        ClaudeModelItems(marked: current) { picked = $0 }
                    }
                } label: {
                    Text(verbatim: current.shortName)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("The model for the next question")
                Spacer(minLength: 8)
                if isThinking {
                    Button {
                        if let question = stop() {
                            text = question
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 14, height: 14)
                    }
                    .buttonBorderShape(.circle)
                    .help("Stop Claude")
                    .accessibilityLabel("Stop")
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .fontWeight(.semibold)
                            .frame(width: 14, height: 14)
                    }
                    .buttonBorderShape(.circle)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmed.isEmpty)
                    .help("Send (⌘↩)")
                    .accessibilityLabel("Send")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        // A field of its own on the card: darker than a dark card, a faint grey on a white one, a clear edge that turns
        // accent while it has the focus.
        .background(
            colorScheme == .dark ? Color.black.opacity(0.28) : Color(white: 0.965),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.20)),
                    lineWidth: isFocused ? 1.5 : 1)
        }
    }

    // MARK: - The "/" list

    /// what was typed after the slash while the list is open: the whole field is one slash word, and Escape didn't close it
    private var slashQuery: String? {
        dismissedText == text ? nil : SlashCommandCatalog.pendingQuery(in: text)
    }

    private var slashMatches: [SlashCommand] {
        guard let query = slashQuery, let model else { return [] }
        return SlashCommandCatalog.filter(model.ai.slashCommands, query: query)
    }

    @ViewBuilder private var slashList: some View {
        if slashQuery != nil, let model {
            if model.ai.settings.useMySetup {
                SlashCommandList(commands: slashMatches, highlighted: highlighted, pick: insert)
            } else {
                SlashCommandHint { router?.open(.settings(pane: .general)) }
            }
        }
    }

    private func insert(_ command: SlashCommand) {
        text = SlashCommandCatalog.insertion(for: command)
        isFocused = true
    }

    /// Arrow keys move through the list, Return and Tab insert the highlighted command, Escape closes it. ⌘↩ still
    /// sends, and with no list open every key is the editor's own.
    private func slashKey(_ press: SwiftUI.KeyPress) -> SwiftUI.KeyPress.Result {
        let matches = slashMatches
        guard slashQuery != nil, model?.ai.settings.useMySetup == true, !press.modifiers.contains(.command) else {
            return .ignored
        }
        switch press.key {
        case .downArrow where !matches.isEmpty:
            highlighted = min(highlighted + 1, matches.count - 1)
        case .upArrow where !matches.isEmpty:
            highlighted = max(highlighted - 1, 0)
        case .return where !matches.isEmpty, .tab where !matches.isEmpty:
            insert(matches[min(highlighted, matches.count - 1)])
        case .escape:
            dismissedText = text
        default:
            return .ignored
        }
        return .handled
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmed.isEmpty, !isThinking else {
            return
        }
        let defaultModel = model?.ai.settings.model ?? AISettings().model
        send(trimmed, picked == defaultModel ? nil : picked)
        text = ""
    }
}

/// "Continue in Claude Code": Claude Code in the checkout of the item's branch, with the whole conversation (Claude's
/// first answer, every question and answer, and the facts) as its first prompt (AI-05's launch); with no checkout on
/// the branch, a menu asks which; nothing without checkouts.
struct ContinueInClaudeCode: View {
    let subject: AISubject
    /// the item the conversation is about: its checkout is where Claude Code starts
    let item: ClaudeCodeContext

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model, let text = model.ai.continuation(of: subject) {
            let context = ClaudeCodeContext.conversation(item, text: text)
            let checkouts = model.workspaces.checkouts
            let match = context.checkout(
                in: checkouts, readings: model.workspaces.readings,
                mergeRequests: model.mergeRequests.list?.mergeRequests ?? [])
            VStack(alignment: .leading, spacing: 6) {
                if let match {
                    ClaudeActionButton(
                        title: "Continue in Claude Code", systemImage: "terminal",
                        help: "Start Claude Code in \(match.name) with the whole conversation and what was sent."
                    ) { chosen in
                        Task { await model.ai.openInClaudeCode(context, in: match, model: chosen) }
                    }
                    .controlSize(.small)
                } else if !checkouts.isEmpty {
                    Menu {
                        Section("Which Checkout?") {
                            ForEach(checkouts) { checkout in
                                Button(checkout.name) {
                                    Task { await model.ai.openInClaudeCode(context, in: checkout) }
                                }
                            }
                        }
                    } label: {
                        Label("Continue in Claude Code", systemImage: "terminal")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .help("No checkout is on this branch: pick the one to start Claude Code in")
                }
                if let result = model.ai.lastLaunch, ClaudeCodeLaunchLine.sameItem(result.context, context) {
                    StatusLine(result.isProblem ? .problem : .ok, result.message)
                }
            }
        }
    }
}
