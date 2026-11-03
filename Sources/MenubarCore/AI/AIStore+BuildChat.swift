import Foundation

extension AIStore {
    /// Asks Claude the first question of a build's chat: a free question about a build of any result, green, red or
    /// running. The facts are the ones "Why Did It Fail?" gathers (``BuildFailureFacts/gather(_:failedTests:flakyHints:client:)``):
    /// the build and its stages, the failed tests, the log narrowed to its error markers and its end, and the commits
    /// since the last green build. Everything is redacted, and the first question shows what it sends and waits for
    /// Send. The chat's answer is kept under ``AISubject/buildChat(_:)``, apart from "Why Did It Fail?", which has
    /// ``AISubject/build(_:)``. Later questions are follow-ups (``followUp(_:question:scope:model:)``).
    ///
    /// - Parameters:
    ///   - question: the user's question
    ///   - build: the build
    ///   - failedTests: the failed tests when the detail has them; read from Jenkins otherwise
    ///   - flakyHints: what the job's recent builds say of the failed stages, when the detail has it
    ///   - model: the model for this answer; `nil` is the one chosen in Settings
    public func ask(
        _ question: String, aboutBuild build: Build, failedTests: [FailedTest]?, flakyHints: [FlakyHint] = [],
        model: ClaudeModel? = nil
    ) async {
        let words = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = AISubject.buildChat(build.id)
        guard settings.isEnabled, !words.isEmpty else {
            return
        }
        switch state(of: subject) {
        case .preparing, .running:
            return
        default:
            break
        }
        // A new question starts the build's conversation anew.
        dismiss(subject)
        openingQuestions[subject] = words
        await ask(subject, model: model) { [jenkins] in
            guard let jenkins else {
                throw AIGatherError("Jenkins isn't set up")
            }
            let facts = try await Self.buildFacts(build, failedTests: failedTests, flakyHints: flakyHints, services: jenkins)
            return .buildQuestion(facts, question: words)
        }
    }
}
