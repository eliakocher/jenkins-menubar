import MenubarCore
import SwiftUI

extension View {
    /// Tells the AI store that a card of a subject is on screen, so an answer that lands meanwhile needs no entry in the
    /// Inbox (Task 7.03). It takes it back when the card goes, or shows another subject.
    ///
    /// - Parameter subject: the card's subject; `nil` marks nothing
    func marksClaudeCardVisible(_ subject: AISubject?) -> some View {
        modifier(ClaudeCardVisibility(subject: subject))
    }
}

private struct ClaudeCardVisibility: ViewModifier {
    let subject: AISubject?

    @Environment(AppModel.self) private var model: AppModel?
    @ViewState private var registered: AISubject?

    func body(content: Content) -> some View {
        content
            .onAppear { sync() }
            .onChange(of: subject) { sync() }
            .onDisappear { drop() }
    }

    private func sync() {
        guard registered != subject else {
            return
        }
        drop()
        if let subject {
            model?.ai.cardAppeared(subject)
            registered = subject
        }
    }

    private func drop() {
        if let registered {
            model?.ai.cardDisappeared(registered)
        }
        registered = nil
    }
}
