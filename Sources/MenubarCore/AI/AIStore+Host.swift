import Foundation

/// The `claude` process of one chat card, hosted as Claude Code's IDE extensions host it (AI-10).
@MainActor
final class ClaudeHostSession {
    let connection: any ClaudeHostConnection
    /// the model it was started with; another model starts a new process
    let model: ClaudeModel
    /// the model Claude Code reported
    var reportedModel: String?
    var isAlive = true
    /// whether a turn is in progress
    var isRunning = false
    var reader: Task<Void, Never>?
    var idle: Task<Void, Never>?
    /// the turn waiting for its `result`
    private var waiter: CheckedContinuation<Void, Never>?
    private var interrupts = 0

    init(connection: any ClaudeHostConnection, model: ClaudeModel) {
        self.connection = connection
        self.model = model
    }

    /// Waits for the turn's end: its `result`, or the process ending.
    func waitForTurn() async {
        await withCheckedContinuation { continuation in
            if isAlive {
                waiter = continuation
            } else {
                continuation.resume()
            }
        }
    }

    /// Lets the waiting turn go on.
    func resume() {
        waiter?.resume()
        waiter = nil
    }

    /// Stop: Claude ends the turn and stays for the next question.
    func interrupt() {
        guard isAlive else { return }
        interrupts += 1
        connection.send(ClaudeHostMessage.interrupt(id: "interrupt-\(interrupts)"))
    }
}

extension ClaudePrompt {
    /// Returns what a follow-up sends to a chat whose Claude Code is still running: only the new question, since the
    /// process has the facts and the conversation; the diff of another scope goes with it. A question that starts with
    /// a command stays first, so that Claude Code runs it.
    ///
    /// - Parameters:
    ///   - question: the question
    ///   - context: more facts for this question alone
    /// - Returns: the message, not redacted yet
    public static func hostFollowUp(question: String, context: String?) -> String {
        guard let context, !context.isEmpty else {
            return question
        }
        if SlashCommandCatalog.leadingCommand(in: question) != nil {
            return question + "\n\n---\nMore code for this message:\n\n" + context
        }
        return "# More code for my next question\n" + context + "\n\n# My question\n" + question
    }
}

extension AIStore {
    /// the hidden default that turns the hosted chats off (`defaults write local.megamonitor ai.hostChats -bool NO`):
    /// the chats with the setup then run headless and read-only, as before AI-10
    static let hostChatsKey = "ai.hostChats"

    /// whether a chat with the user's setup runs as a hosted Claude Code (AI-10); on unless the hidden default says no
    var hostsChats: Bool {
        defaults.object(forKey: Self.hostChatsKey) as? Bool ?? true
    }

    // MARK: - For the views

    /// Returns the commands of the "/" list: the ones Claude Code reported for this chat, else the ones read from the
    /// setup's folders.
    ///
    /// - Parameter subject: the chat, if known
    public func commands(for subject: AISubject?) -> [SlashCommand] {
        if let subject, let reported = hostChats[subject]?.commands, !reported.isEmpty {
            return reported
        }
        return slashCommands
    }

    /// Remembers the checkout a chat's Claude Code starts in, as its card found it; a question about code starts in its
    /// own readable checkout first.
    ///
    /// - Parameters:
    ///   - path: the checkout's folder, or `nil`
    ///   - subject: the chat
    public func noteWorkingFolder(_ path: String?, for subject: AISubject) {
        hostFolders[subject] = path.flatMap { $0.hasPrefix("/") ? $0 : nil }
    }

    /// Answers a tool call or a question of a hosted chat, with the developer's click (AI-10). Nothing else ever
    /// answers one: no request is allowed by the app on its own.
    ///
    /// - Parameters:
    ///   - request: the request
    ///   - subject: the chat
    ///   - choice: what the developer chose
    public func answer(_ request: ClaudeHostRequest, of subject: AISubject, with choice: ClaudePermissionChoice) {
        guard let session = hostSessions[subject], session.isAlive,
            hostChats[subject]?.turn?.pending.contains(where: { $0.requestID == request.requestID }) == true
        else {
            return
        }
        session.connection.send(
            ClaudeHostMessage.response(
                to: request.requestID, decision: ClaudePermissionAnswer.decision(choice, for: request)))
        hostChats[subject]?.turn?.answered(request.requestID)
        let what =
            switch choice {
            case .allowOnce: "allowed once"
            case .allowAlways: "allowed for the chat"
            case .deny: "denied"
            case .answers: "answered"
            }
        // The tool's name only, never its input.
        record("Claude chat: \(request.toolName) \(what)", level: .info, source: .app)
    }

    // MARK: - Turns

    /// Returns the folder a chat's Claude Code starts in: the question's readable checkout, else the one its card found.
    func hostFolder(of subject: AISubject, prompt: ClaudePrompt) -> String? {
        ClaudeEngine.readableFolder(of: prompt) ?? hostFolders[subject]
    }

    /// Runs one turn of a hosted chat (AI-10) and waits for its end, while the card shows its text, tool calls and
    /// requests as they come. A first answer, a process that ended (idle, budget) and another model start a new
    /// process with `opening`, which has the facts and the conversation so far; a follow-up to a running one sends only
    /// `message`. Stop (the task's cancellation) sends `interrupt`, and the process stays.
    ///
    /// - Parameters:
    ///   - subject: the chat
    ///   - message: the follow-up's message for a running process; `nil` for a first answer
    ///   - opening: the whole prompt's text, redacted, for a new process
    ///   - folder: the working folder, or `nil` for the app's own empty one
    ///   - model: the model
    ///   - setup: the user's setup
    /// - Returns: the turn as a run, and its raw response
    /// - Throws: ``ClaudeFailure``
    func hostRun(
        _ subject: AISubject, message: String?, opening: String, folder: String?, model: ClaudeModel, setup: ClaudeSetup
    ) async throws(ClaudeFailure) -> (run: ClaudeRun, raw: ClaudeRawResponse) {
        var text = message ?? opening
        var session = hostSessions[subject]
        if message == nil || session?.isAlive != true || session?.model != model {
            endHostSession(subject)
            session = try await startHost(subject, folder: folder, model: model, setup: setup)
            text = opening
        }
        guard let session else {
            throw .couldNotRun("Claude Code didn't start")
        }
        session.idle?.cancel()
        hostChats[subject, default: ClaudeHostChat()].turn = ClaudeHostTurn()
        session.isRunning = true
        session.connection.send(ClaudeHostMessage.user(text))
        await withTaskCancellationHandler {
            await session.waitForTurn()
        } onCancel: {
            Task { @MainActor in session.interrupt() }
        }
        session.isRunning = false
        let turn = hostChats[subject]?.turn ?? ClaudeHostTurn()
        let tail = session.connection.stderrTail()
        guard let result = turn.result else {
            // The process ended without finishing the turn.
            if hostSessions[subject] === session {
                endHostSession(subject)
            }
            if ClaudeFailure.saysOutdated(tail) {
                throw .outdated(required: ClaudeFailure.requiredVersion(in: tail))
            }
            let lastLine = tail.split(whereSeparator: \.isNewline).last.map { String($0.prefix(300)) }
            throw .failed(status: session.connection.exitStatus() ?? -1, lastLine: lastLine)
        }
        let run = turn.run(fallbackModel: session.reportedModel ?? model.rawValue)
        let raw = turn.raw(model: session.reportedModel, stderrTail: tail.isEmpty ? nil : tail)
        if result.subtype == "error_max_budget_usd" {
            // The next question starts anew, with the conversation so far.
            endHostSession(subject)
        } else {
            scheduleHostIdle(subject, session: session)
        }
        guard !run.isError else {
            if ClaudeFailure.saysOutdated(run.errorMessage) {
                throw .outdated(required: ClaudeFailure.requiredVersion(in: run.errorMessage))
            }
            throw .answeredError(run)
        }
        return (run, raw)
    }

    /// Starts a chat's Claude Code: `initialize` first, then the reader that turns its lines into the card's state.
    private func startHost(
        _ subject: AISubject, folder: String?, model: ClaudeModel, setup: ClaudeSetup
    ) async throws(ClaudeFailure) -> ClaudeHostSession {
        guard let claude = await engine.locate() else {
            throw .notFound
        }
        let workingFolder: URL
        if let folder, FileManager.default.fileExists(atPath: folder) {
            workingFolder = URL(filePath: folder, directoryHint: .isDirectory)
        } else {
            try? FileManager.default.createDirectory(at: hostScratchFolder, withIntermediateDirectories: true)
            workingFolder = hostScratchFolder
        }
        let connection: any ClaudeHostConnection
        do {
            connection = try hostLauncher.start(
                executable: claude, arguments: ClaudeEngine.hostArguments(model: model, effort: settings.effort, setup: setup),
                folder: workingFolder, environment: ClaudeEngine.hostEnvironment(setup: setup))
        } catch {
            throw .couldNotRun(error.localizedDescription)
        }
        let session = ClaudeHostSession(connection: connection, model: model)
        hostSessions[subject] = session
        session.reader = Task { [weak self] in
            for await line in connection.lines {
                self?.hostReceived(line, of: subject, session: session)
            }
            self?.hostEnded(subject, session: session)
        }
        connection.send(ClaudeHostMessage.initialize())
        return session
    }

    private func hostReceived(_ line: Data, of subject: AISubject, session: ClaudeHostSession) {
        guard hostSessions[subject] === session else { return }
        for event in ClaudeHostMessage.events(in: line) {
            switch event {
            case .initialized(let commands):
                hostChats[subject, default: ClaudeHostChat()].commands = commands
            case .started(let model):
                session.reportedModel = model ?? session.reportedModel
            case .unsupported(let id):
                session.connection.send(ClaudeHostMessage.unsupported(id))
            default:
                hostChats[subject]?.turn?.apply(event)
                if case .finished = event {
                    session.resume()
                }
            }
        }
    }

    private func hostEnded(_ subject: AISubject, session: ClaudeHostSession) {
        session.isAlive = false
        session.resume()
        if hostSessions[subject] === session {
            hostSessions[subject] = nil
            hostChats[subject]?.turn?.pending = []
        }
    }

    /// Ends a chat's Claude Code: stdin closes, and the process is ended a few seconds later if it is still there.
    func endHostSession(_ subject: AISubject) {
        guard let session = hostSessions.removeValue(forKey: subject) else { return }
        session.idle?.cancel()
        session.isAlive = false
        session.resume()
        let connection = session.connection
        connection.closeInput()
        Task {
            try? await Task.sleep(for: .seconds(5))
            connection.terminate()
        }
        hostChats[subject]?.turn = nil
    }

    /// Ends a chat's idle Claude Code after ``hostIdleTimeout``.
    private func scheduleHostIdle(_ subject: AISubject, session: ClaudeHostSession) {
        session.idle?.cancel()
        let timeout = hostIdleTimeout
        session.idle = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.hostSessions[subject] === session, !session.isRunning else { return }
            self.endHostSession(subject)
        }
    }

    /// A chat's card left the screen: its Claude Code ends after ``hostHiddenTimeout`` unless a card shows it again
    /// or a turn is running; a running turn finishes, and the idle time ends it later.
    func hostCardLeft(_ subject: AISubject) {
        guard let session = hostSessions[subject] else { return }
        let timeout = hostHiddenTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, self.hostSessions[subject] === session, !self.isCardVisible(subject), !session.isRunning else {
                return
            }
            self.endHostSession(subject)
        }
    }
}
