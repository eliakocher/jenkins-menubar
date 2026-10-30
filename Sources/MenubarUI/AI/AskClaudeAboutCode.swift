import MenubarCore
import SwiftUI

// MARK: - Aiming the chat

/// Aims the merge request's Claude chat at a scope of its code and brings the chat into view (AI-07); in the environment
/// of the merge request detail while the Claude features are on, `nil` otherwise. Only views call it, on the main actor.
struct AskClaudeAboutCodeAction: @unchecked Sendable {
    let open: @MainActor (CodeScope) -> Void

    @MainActor
    func callAsFunction(_ scope: CodeScope) {
        open(scope)
    }
}

private struct AskClaudeAboutCodeKey: EnvironmentKey {
    static let defaultValue: AskClaudeAboutCodeAction? = nil
}

extension EnvironmentValues {
    /// aims the chat at a scope; `nil` while the Claude features are off, and in the gallery
    var askClaudeAboutCode: AskClaudeAboutCodeAction? {
        get { self[AskClaudeAboutCodeKey.self] }
        set { self[AskClaudeAboutCodeKey.self] = newValue }
    }
}

extension View {
    /// Offers "Ask Claude" about a merge request's code to the views inside (AI-07): it sets the scope chip of the
    /// Claude card's field, which takes the focus.
    ///
    /// - Parameters:
    ///   - mergeRequest: the merge request
    ///   - reveal: runs after the scope is set, to bring the Claude card into view
    func askClaudeAboutCode(_ mergeRequest: MergeRequest, reveal: @escaping () -> Void = {}) -> some View {
        modifier(AskClaudeAboutCodeModifier(mergeRequest: mergeRequest, reveal: reveal))
    }
}

private struct AskClaudeAboutCodeModifier: ViewModifier {
    let mergeRequest: MergeRequest
    let reveal: () -> Void

    @Environment(AppModel.self) private var model: AppModel?

    func body(content: Content) -> some View {
        content.environment(
            \.askClaudeAboutCode,
            model?.ai.isOffered == true
                ? AskClaudeAboutCodeAction { scope in
                    model?.ai.aim(at: scope, of: mergeRequest)
                    reveal()
                } : nil)
    }
}

/// "Ask Claude About This MR…" as a menu item, for the header's ⋯ menu; nothing while Claude is off.
struct AskClaudeAboutMergeRequestItem: View {
    @Environment(\.askClaudeAboutCode) private var ask

    var body: some View {
        if let ask {
            Button("Ask Claude About This MR…") { ask(.mergeRequest) }
        }
    }
}

// MARK: - The card

/// The merge request's Claude card: one inline chat about the merge request's code (AI-07). Quick picks (Review This,
/// Explain This, Find Bugs, Suggest Tests) fill the field; a scope chip, set from the diff, narrows the question to
/// lines or a file, and no chip means the whole merge request. Shows only while the Claude features are on.
struct MergeRequestClaudeCard: View {
    let mergeRequest: MergeRequest

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model, model.ai.isOffered {
            let scope = model.ai.pendingScope(of: mergeRequest)
            let checkout = checkout(in: model)
            DetailCard("Claude", symbol: "sparkles", width: .fullWidth) {
                InlineClaudeChat(
                    subject: .codeChat(mergeRequest.reference), item: .mergeRequest(mergeRequest),
                    placeholder: "Ask about this MR…", followUpPlaceholder: "Ask about this MR…",
                    quickPicks: CodeChat.quickPicks, scope: scope, clearScope: { model.ai.clearScope(of: mergeRequest) },
                    focusCount: model.ai.aimCount, commandsFolder: checkout?.path,
                    ask: { question, picked in
                        send(question, scope: scope, model: model, checkout: checkout, picked: picked, first: true)
                    },
                    followUp: { question, picked in
                        send(question, scope: scope, model: model, checkout: checkout, picked: picked, first: false)
                    }
                ) { state in
                    if state == .idle {
                        Label {
                            Text(access(of: scope, checkout: checkout))
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: checkout == nil ? "doc.plaintext" : "folder.badge.gearshape")
                        }
                        .font(.callout)
                        // Readable grey on the card, stronger than `.secondary`.
                        .foregroundStyle(Color.primary.opacity(0.7))
                    }
                }
            }
        }
    }

    /// The checkout on the merge request's source branch, which Claude may read.
    private func checkout(in model: AppModel) -> CheckoutAccess? {
        let store = model.workspaces
        guard let checkout = ClaudeCodeContext.mergeRequest(mergeRequest).checkout(
            in: store.checkouts, readings: store.readings, mergeRequests: [])
        else {
            return nil
        }
        let access = CheckoutAccess(
            path: checkout.path, name: checkout.name, branch: store.readings[checkout.id]?.state?.status.branch)
        return CodeQuestionFacts.readable(access, sourceBranch: mergeRequest.sourceBranch)
    }

    private func send(
        _ question: String, scope: CodeScope?, model: AppModel, checkout: CheckoutAccess?, picked: ClaudeModel?,
        first: Bool
    ) {
        let mergeRequest = mergeRequest
        let scope = scope ?? .mergeRequest
        let changes = model.mergeRequestChanges.state(of: mergeRequest)
        let description = model.descriptions.description(of: DescriptionSource(mergeRequest))
        let loaded = changes.isCurrent ? changes.changes : nil
        let text = description.isCurrent ? description.text : nil
        Task {
            if first {
                await model.ai.ask(
                    question, about: scope, of: mergeRequest, changes: loaded, description: text, checkout: checkout,
                    model: picked)
            } else {
                await model.ai.followUp(
                    question, about: scope, of: mergeRequest, changes: loaded, description: text, checkout: checkout,
                    model: picked)
            }
        }
    }

    /// what Claude gets, in a sentence
    private func access(of scope: CodeScope?, checkout: CheckoutAccess?) -> String {
        let words =
            switch scope {
            case .lines: "these lines with the code around them"
            case .file: "this file"
            case .mergeRequest, nil: "every file, cut when very long"
            }
        let facts = "Claude gets the title, the description and the diff of \(words)"
        guard let checkout else {
            return facts + ". No checkout has this branch, so it reads no other files."
        }
        return facts + ", and may read \(checkout.name) (read only, no commands)."
    }
}
