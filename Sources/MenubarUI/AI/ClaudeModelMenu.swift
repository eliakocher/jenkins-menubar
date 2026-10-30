import MenubarCore
import SwiftUI

/// The models to pick from, as menu items with only their names: "Opus 5.5", "Sonnet 5.5", "Haiku 5.5" (the user,
/// 2026-10-30: no details). With `marked`, that model is checked.
struct ClaudeModelItems: View {
    /// the model to check: the one that answered
    var marked: ClaudeModel?
    let pick: (ClaudeModel) -> Void

    var body: some View {
        ForEach(ClaudeModel.allCases, id: \.self) { model in
            Button {
                pick(model)
            } label: {
                if model == marked {
                    Label(model.shortName, systemImage: "checkmark")
                } else {
                    Text(verbatim: model.shortName)
                }
            }
        }
    }
}

/// The look of a Claude button: bordered, or prominent for the main action of a row.
struct ClaudeButtonLook: ViewModifier {
    var prominent = false

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// A button that asks Claude, as a split button: a click uses Settings' model (the default), the arrow picks the model
/// for this run. Used by every Claude action:
/// Why Did It Fail?, Summarize Discussion, Write Digest and Open in Claude Code.
struct ClaudeActionButton: View {
    let title: String
    var systemImage: String?
    var prominent = false
    /// what the action does, for the tooltip
    var help: String
    var isDisabled = false
    /// runs with the model picked for this run, or `nil` for Settings' model
    let action: (ClaudeModel?) -> Void

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        let defaultModel = model?.ai.settings.model ?? AISettings().model
        Menu {
            Section("Ask With") {
                ClaudeModelItems { action($0) }
            }
        } label: {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        } primaryAction: {
            action(nil)
        }
        .menuStyle(.button)
        .modifier(ClaudeButtonLook(prominent: prominent))
        .fixedSize()
        .disabled(isDisabled)
        .help("\(help) Uses \(defaultModel.shortName); the arrow picks another model.")
    }
}

/// "Ask Again With ▾" under an answer: sends the same facts to another model and replaces the answer. The model that
/// answered is checked.
struct AskAgainMenu: View {
    let subject: AISubject
    /// the model that answered, when known
    var answered: ClaudeModel?

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model {
            Menu("Ask Again With") {
                ClaudeModelItems(marked: answered) { picked in
                    Task { await model.ai.askAgain(subject, model: picked) }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Send the same facts to another model and compare")
        }
    }
}
