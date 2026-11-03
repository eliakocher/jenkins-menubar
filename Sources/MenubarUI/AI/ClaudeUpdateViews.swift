import MenubarCore
import SwiftUI

/// "Copy Command" next to the problem "Claude Code is too old for this model": copies `claude update` for the Terminal.
struct ClaudeUpdateCommandButton: View {
    @ViewState private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ClaudeFailure.updateCommand, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy Command", systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.link)
        .help("Copy “\(ClaudeFailure.updateCommand)”, then run it in Terminal")
    }
}

extension ClaudeFailure {
    /// whether a failure's text is the one of an outdated `claude`, which the views answer with "Copy Command" instead of "Try Again"
    static func isOutdated(message: String) -> Bool {
        message == outdatedMessage
    }
}
