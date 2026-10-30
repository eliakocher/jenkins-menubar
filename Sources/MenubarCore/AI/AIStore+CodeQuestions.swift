import Foundation

extension AIStore {
    /// Returns what the next question of a merge request's chat is about; `nil` is the whole merge request.
    ///
    /// - Parameter mergeRequest: the merge request
    public func pendingScope(of mergeRequest: MergeRequest) -> CodeScope? {
        pendingScopes[mergeRequest.reference]
    }

    /// Aims the merge request's chat at a scope (AI-07): the lines, the file or the whole merge request. A scope set
    /// before is replaced; the whole merge request is no chip. Counts the aim, so that the chat's field takes the focus.
    ///
    /// - Parameters:
    ///   - scope: what the next question is about
    ///   - mergeRequest: the merge request
    public func aim(at scope: CodeScope, of mergeRequest: MergeRequest) {
        pendingScopes[mergeRequest.reference] = scope == .mergeRequest ? nil : scope
        aimCount += 1
    }

    /// Takes the scope chip off: the next question is about the whole merge request.
    ///
    /// - Parameter mergeRequest: the merge request
    public func clearScope(of mergeRequest: MergeRequest) {
        pendingScopes[mergeRequest.reference] = nil
    }

    /// Asks Claude the first question of a merge request's chat (AI-07): about picked lines, a file or the whole merge
    /// request. A chat that was there starts anew.
    ///
    /// The facts are packed by the app, as for "Why Did It Fail?": the merge request's title, reference, author,
    /// branches, head commit and description from GitLab, and the scope's diff, with the pages the Changes card hasn't
    /// loaded read now (``CodeQuestionFacts/filling(_:for:client:source:)``). A checkout on the source branch is
    /// readable by Claude with Read, Grep and Glob only; without one Claude gets no tool. Everything is redacted, and the
    /// first question shows what it sends and waits for Send. Later questions are follow-ups
    /// (``followUp(_:about:of:changes:description:checkout:model:)``).
    ///
    /// - Parameters:
    ///   - question: the user's question
    ///   - scope: what it is about
    ///   - mergeRequest: the merge request
    ///   - changes: the changes as the Changes card has them; `nil` before they loaded
    ///   - description: the description, when loaded; GitLab's otherwise
    ///   - checkout: the checkout of the merge request's branch, when there is one
    ///   - model: the model for this answer; `nil` is the one chosen in Settings
    public func ask(
        _ question: String, about scope: CodeScope, of mergeRequest: MergeRequest, changes: MergeRequestChanges?,
        description: String?, checkout: CheckoutAccess?, model: ClaudeModel? = nil
    ) async {
        let words = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = AISubject.codeChat(mergeRequest.reference)
        guard settings.isEnabled, !words.isEmpty else {
            return
        }
        switch state(of: subject) {
        case .preparing, .running:
            return
        default:
            break
        }
        dismiss(subject)
        openingQuestions[subject] = words
        openingScopes[subject] = scope
        pendingScopes[mergeRequest.reference] = nil
        let gitLab = gitLab
        let runner = runner
        await ask(subject, model: model) {
            let facts = try await Self.codeFacts(
                scope: scope, of: mergeRequest, changes: changes, description: description, checkout: checkout,
                gitLab: gitLab, runner: runner)
            return .codeQuestion(facts, question: words)
        }
    }

    /// Asks a follow-up in a merge request's chat (AI-07), about a scope that may be another than the first question's:
    /// then its diff is gathered the same way and goes before the question. Does nothing before there is an answer.
    ///
    /// - Parameters:
    ///   - question: the user's question
    ///   - scope: what it is about
    ///   - mergeRequest: the merge request
    ///   - changes: the changes as the Changes card has them; `nil` before they loaded
    ///   - description: the description, when loaded; GitLab's otherwise
    ///   - checkout: the checkout of the merge request's branch, when there is one
    ///   - model: the model for this turn; `nil` is the one chosen in Settings
    public func followUp(
        _ question: String, about scope: CodeScope, of mergeRequest: MergeRequest, changes: MergeRequestChanges?,
        description: String?, checkout: CheckoutAccess?, model: ClaudeModel? = nil
    ) async {
        let subject = AISubject.codeChat(mergeRequest.reference)
        let gitLab = gitLab
        let runner = runner
        scopeContexts[subject] = { other in
            let facts = try await Self.codeFacts(
                scope: other, of: mergeRequest, changes: changes, description: description, checkout: checkout,
                gitLab: gitLab, runner: runner)
            return ClaudePrompt.followUpDiff(facts)
        }
        pendingScopes[mergeRequest.reference] = nil
        await followUp(subject, question: question, scope: scope, model: model)
    }

    /// Gathers the facts of a question about code: GitLab's meta data of the merge request, the scope's diff, and the
    /// checkout Claude may read, with its HEAD.
    private nonisolated static func codeFacts(
        scope: CodeScope, of mergeRequest: MergeRequest, changes: MergeRequestChanges?, description: String?,
        checkout: CheckoutAccess?, gitLab: GitLabServices?, runner: any ProcessRunner
    ) async throws -> CodeQuestionFacts {
        guard let gitLab else {
            throw AIGatherError("GitLab isn't set up")
        }
        let client: GitLabClient
        switch await gitLab.session() {
        case .success(let session): client = session.client
        case .failure(let error): throw AIGatherError(error.problem.message)
        }
        let source = DescriptionSource(mergeRequest)
        let meta: CodeQuestionMeta? =
            if let operation = GitLabOperation.codeQuestionMeta(of: source) { try? await client.send(operation) } else { nil }
        let filled = await CodeQuestionFacts.filling(
            changes ?? MergeRequestChanges(files: [], isComplete: false), for: scope, client: client, source: source)
        var access = CodeQuestionFacts.readable(checkout, sourceBranch: mergeRequest.sourceBranch)
        if let path = access?.path {
            access?.head = await head(of: path, runner: runner)
        }
        return CodeQuestionFacts(
            reference: mergeRequest.reference, title: mergeRequest.title, author: mergeRequest.author,
            sourceBranch: mergeRequest.sourceBranch, targetBranch: meta?.targetBranch, headCommit: meta?.headCommit,
            description: description ?? meta?.description, scope: scope, changes: filled, checkout: access)
    }

    /// Returns a checkout's HEAD commit, read with `git rev-parse` without taking a lock; `nil` when git didn't say.
    private nonisolated static func head(of path: String, runner: any ProcessRunner) async -> String? {
        let arguments = GitReader.arguments(in: path, ["rev-parse", "--verify", "--end-of-options", "HEAD"])
        guard let output = try? await runner.run(GitReader.git, arguments: arguments, input: nil, timeout: GitReader.timeout),
            output.status == 0
        else {
            return nil
        }
        let commit = String(decoding: output.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.isEmpty ? nil : commit
    }
}
