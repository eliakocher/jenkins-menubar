import MenubarCore
import SwiftUI

/// What the last Continue in Claude Code of this item did or why it failed, under the chat's buttons; nothing before the first.
struct ClaudeCodeLaunchLine: View {
    /// the item the line belongs to: it shows only the result of its own Continue in Claude Code
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
        case (.conversation(let a, _), .conversation(let b, _)): sameItem(a, b)
        default: false
        }
    }
}
