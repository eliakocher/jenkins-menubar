import MenubarCore
import SwiftUI

/// "Open in Claude Code" (AI-05): opens Terminal in the checkout the item belongs in, running Claude Code with the item
/// as its first prompt. With no checkout on the item's branch, a menu asks which checkout; with no checkout at all, the
/// button points to Settings → Repositories. Hidden while the Claude features are off or `claude` isn't installed.
struct OpenInClaudeCodeButton: View {
    let context: ClaudeCodeContext
    var prominent = false

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model, model.ai.isOffered {
            let checkouts = model.workspaces.checkouts
            let match = context.checkout(
                in: checkouts, readings: model.workspaces.readings,
                mergeRequests: model.mergeRequests.list?.mergeRequests ?? [])
            Group {
                if let match {
                    Button("Open in Claude Code") { open(match, model: model) }
                        .help("Start Claude Code in \(match.name) with this as its first prompt")
                } else if checkouts.isEmpty {
                    Button("Open in Claude Code") {}
                        .disabled(true)
                        .help("Add your checkouts in Settings → Repositories")
                } else {
                    Menu("Open in Claude Code") {
                        Section("Which Checkout?") {
                            ForEach(checkouts) { checkout in
                                Button(checkout.name) { open(checkout, model: model) }
                            }
                        }
                    }
                    .fixedSize()
                    .help("No checkout is on this branch: pick the one to start Claude Code in")
                }
            }
            .modifier(ButtonLook(prominent: prominent))
        }
    }

    private func open(_ checkout: Checkout, model: AppModel) {
        Task { await model.ai.openInClaudeCode(context, in: checkout) }
    }

    private struct ButtonLook: ViewModifier {
        let prominent: Bool

        func body(content: Content) -> some View {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

/// What the last Open in Claude Code of this item did or why it failed, under the buttons; nothing before the first.
struct ClaudeCodeLaunchLine: View {
    /// the item the line belongs to: it shows only the result of its own Open in Claude Code
    let context: ClaudeCodeContext

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model, model.ai.isOffered, let result = model.ai.lastLaunch, Self.sameItem(result.context, context) {
            StatusLine(result.isProblem ? .problem : .ok, result.message)
        }
    }

    /// whether two contexts are about the same item, whatever was loaded with them since
    static func sameItem(_ one: ClaudeCodeContext, _ other: ClaudeCodeContext) -> Bool {
        switch (one, other) {
        case (.workItem(let a), .workItem(let b)): a.id == b.id
        case (.mergeRequest(let a), .mergeRequest(let b)): a.id == b.id
        case (.build(let a, _, _), .build(let b, _, _)): a.id == b.id
        case (.workspace(let a, _), .workspace(let b, _)): a.id == b.id
        default: false
        }
    }
}
