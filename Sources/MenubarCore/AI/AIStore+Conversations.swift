import Foundation

// MARK: - A question about a work item

extension ClaudePrompt {
    /// the system prompt of a question about a work item
    static let workItemInstructions = """
        You answer a developer's question about a GitLab work item (an issue, task or epic). You get its title, state, \
        labels, people and description; answer from them. You can't run commands, open links or change anything. \
        Answer in Markdown, concise and concrete: most important first. Say plainly when the facts don't tell enough \
        to be sure.
        """

    /// the most of a work item's description that is sent, in characters
    static let workItemDescriptionCharacters = 8_000

    /// Returns the prompt of a question about a work item (AI-08): its reference, title, type, state, labels, people,
    /// weight, epic and due date, its description, and the question last.
    ///
    /// - Parameters:
    ///   - item: the work item
    ///   - description: its description, when loaded
    ///   - question: the user's question
    /// - Returns: the prompt, not redacted yet
    public static func workItemQuestion(_ item: WorkItem, description: String?, question: String) -> ClaudePrompt {
        func person(_ person: MergeRequest.Person) -> String {
            person.name.isEmpty ? person.username : "\(person.name) (\(person.username))"
        }
        var lines = ["Answer my question about this work item.", "", "# Work item"]
        lines.append("\(item.reference) \"\(item.title)\" (\(item.type.rawValue.lowercased()), \(item.state.rawValue))")
        if !item.labels.isEmpty {
            lines.append("Labels: \(item.labels.map(\.title).joined(separator: ", "))")
        }
        if let author = item.author {
            lines.append("Opened by: \(person(author))")
        }
        if let assignees = item.assignees, !assignees.isEmpty {
            lines.append("Assigned to: \(assignees.map(person).joined(separator: ", "))")
        }
        if let weight = item.weight {
            lines.append("Weight: \(weight)")
        }
        if let due = item.dueDate {
            lines.append("Due: \(due)")
        }
        if let text = description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            lines += ["", "# Description", head(text, characters: workItemDescriptionCharacters)]
        }
        lines += ["", "# My question", question]
        var prompt = ClaudePrompt(useCase: .askAboutItem, instructions: workItemInstructions, text: lines.joined(separator: "\n"))
        prompt.question = question
        return prompt
    }
}

// MARK: - The conversation

extension AIStore {
    /// Returns the follow-ups of a subject's answer, oldest first.
    ///
    /// - Parameter subject: the subject
    public func turns(of subject: AISubject) -> [ConversationTurn] {
        conversations[subject]?.turns ?? []
    }

    /// Asks Claude a question about a work item (AI-08): the item's facts and the question go as one prompt, like a
    /// question about code; the first one shows what it sends and waits for Send. The answer is Markdown, and can be
    /// followed up.
    ///
    /// - Parameters:
    ///   - question: the user's question
    ///   - item: the work item
    ///   - description: the description, when loaded
    ///   - model: the model for this answer; `nil` is the one chosen in Settings
    public func ask(_ question: String, about item: WorkItem, description: String?, model: ClaudeModel? = nil) async {
        let words = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = AISubject.workItem(item.reference)
        guard settings.isEnabled, !words.isEmpty else {
            return
        }
        switch state(of: subject) {
        case .preparing, .running:
            return
        default:
            break
        }
        // A new question starts the item's conversation anew.
        dismiss(subject)
        openingQuestions[subject] = words
        await ask(subject, model: model) {
            ClaudePrompt.workItemQuestion(item, description: description, question: words)
        }
    }

    /// Asks a follow-up to a subject's answer (AI-08). The first answer's facts go once, then the conversation so far,
    /// then the question (``ClaudePrompt/followUp(to:history:question:)``); the answer joins the thread as Markdown. Each
    /// turn keeps its own model. Does nothing while a turn is being answered, before there is an answer, or with Claude
    /// off.
    ///
    /// - Parameters:
    ///   - subject: the subject whose answer is followed up
    ///   - question: the user's question
    ///   - scope: what the question is about, in a merge request's code chat
    ///   - model: the model for this turn; `nil` is the one chosen in Settings
    public func followUp(
        _ subject: AISubject, question: String, scope: CodeScope? = nil, model: ClaudeModel? = nil
    ) async {
        let words = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.isEnabled, !words.isEmpty, case .answered(let answer) = state(of: subject),
            conversations[subject]?.isThinking != true
        else {
            return
        }
        let history = turns(of: subject)
        let turn = ConversationTurn(question: words, askedAt: now(), scope: scope)
        conversations[subject, default: Conversation()].turns.append(turn)
        remember(subject)
        let task = Task {
            await self.answer(turn, of: subject, to: answer, history: history, model: model)
        }
        followUpTasks[subject] = task
        await task.value
        if followUpTasks[subject] == task {
            followUpTasks[subject] = nil
        }
    }

    /// Stops the turn Claude is answering: `claude` is ended and the turn goes, so its question can be asked again.
    ///
    /// - Parameter subject: the subject
    /// - Returns: the question of the stopped turn, to put back in the field; `nil` when nothing was being answered
    @discardableResult
    public func stopFollowUp(of subject: AISubject) -> String? {
        followUpTasks[subject]?.cancel()
        followUpTasks[subject] = nil
        guard let turn = conversations[subject]?.turns.last(where: { $0.status == .thinking }) else {
            return nil
        }
        conversations[subject]?.turns.removeAll { $0.id == turn.id }
        return turn.question
    }

    /// Asks a failed turn again: it goes, and its question is asked anew at the end of the thread.
    ///
    /// - Parameters:
    ///   - turn: the failed turn
    ///   - subject: the subject
    ///   - model: the model for the new turn
    public func retry(_ turn: ConversationTurn, of subject: AISubject, model: ClaudeModel? = nil) async {
        guard case .failed = turn.status else {
            return
        }
        remove(turn, of: subject)
        await followUp(subject, question: turn.question, scope: turn.scope, model: model)
    }

    /// Drops a turn from the thread, as for a failed one the user doesn't want to see.
    ///
    /// - Parameters:
    ///   - turn: the turn
    ///   - subject: the subject
    public func remove(_ turn: ConversationTurn, of subject: AISubject) {
        conversations[subject]?.turns.removeAll { $0.id == turn.id && $0.status != .thinking }
    }

    /// Returns Claude Code's first prompt for a conversation: Claude's first answer, every answered turn and the facts.
    ///
    /// - Parameter subject: the subject
    /// - Returns: the text, redacted; `nil` before there is an answer
    public func continuation(of subject: AISubject) -> String? {
        guard case .answered(let answer) = state(of: subject) else {
            return nil
        }
        return SecretRedactor().redact(ClaudePrompt.continuation(of: answer, turns: turns(of: subject)))
    }

    // MARK: Inside

    /// Forgets a subject's conversation and ends the turn in progress.
    func clearConversation(of subject: AISubject) {
        followUpTasks[subject]?.cancel()
        followUpTasks[subject] = nil
        conversations[subject] = nil
        conversationOrder.removeAll { $0 == subject }
    }

    /// Marks a subject's conversation as the newest, and lets the oldest idle ones go beyond ``Conversation/kept``.
    private func remember(_ subject: AISubject) {
        conversationOrder.removeAll { $0 == subject }
        conversationOrder.append(subject)
        while conversationOrder.count > Conversation.kept,
            let oldest = conversationOrder.first(where: { conversations[$0]?.isThinking != true && $0 != subject })
        {
            conversationOrder.removeAll { $0 == oldest }
            conversations[oldest] = nil
        }
    }

    /// Sends a turn and keeps its answer or its failure in the thread, unless it was stopped meanwhile.
    private func answer(
        _ turn: ConversationTurn, of subject: AISubject, to answer: AIAnswer, history: [ConversationTurn], model chosen: ClaudeModel?
    ) async {
        let redactor = SecretRedactor(knownSecrets: await knownSecrets())
        // Another scope than the first question's brings its own diff.
        var context: String?
        if let scope = turn.scope, scope != openingScopes[subject], let gather = scopeContexts[subject] {
            do {
                context = try await gather(scope)
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? AIGatherError)?.message ?? error.localizedDescription
                if let index = conversations[subject]?.turns.firstIndex(where: { $0.id == turn.id }) {
                    conversations[subject]?.turns[index].status = .failed(message)
                }
                return
            }
        }
        let prompt = ClaudePrompt.followUp(to: answer, history: history, question: turn.question, context: context)
            .redacted(by: redactor)
        let model = chosen ?? settings.model
        let status: ConversationTurn.Status
        do {
            let setup = await setupForChat(of: prompt, followUp: true)
            let run = try await engine.run(
                setup == nil ? prompt : prompt.startingWithCommand(), model: model, effort: settings.effort, setup: setup)
            guard !Task.isCancelled else { return }
            count(run, prompt: prompt, model: model, followUp: true)
            if let text = run.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                status = .answered(text, model: run.model ?? model.rawValue, at: now())
            } else {
                status = .failed(ClaudeFailure.unreadableAnswer(run).message)
            }
        } catch {
            guard !Task.isCancelled else { return }
            if let run = error.run {
                count(run, prompt: prompt, model: model, followUp: true)
            } else {
                let how = if case .failed(let code, _) = error { "exit \(code)" } else { "no answer" }
                record("Claude: \(prompt.useCase.logName) follow-up failed, \(how)", level: .warning, source: .app)
            }
            status = .failed(error.message)
        }
        guard let index = conversations[subject]?.turns.firstIndex(where: { $0.id == turn.id }) else {
            return
        }
        conversations[subject]?.turns[index].status = status
    }
}
