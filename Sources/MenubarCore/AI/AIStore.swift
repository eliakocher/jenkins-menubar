import Foundation
import Observation

/// What an AI answer is about: a build, a merge request's discussion, or the digest.
public enum AISubject: Hashable, Sendable {
    case build(BuildID)
    /// a merge request, by its full reference
    case mergeRequest(String)
    case digest
    /// the inline chat about a merge request's code, by the merge request's full reference (AI-07)
    case codeChat(String)
    /// a question about a work item, by its full reference (AI-08)
    case workItem(String)
}

/// A first answer in progress, and where its subject stood before it began.
struct FirstRun {
    var task: Task<Void, Never>
    var before: AIAnswerState?
}

/// Whether `claude` is installed, as last looked for.
public enum ClaudeAvailability: Hashable, Sendable {
    case unknown
    case found
    case missing
}

/// An answer of Claude's, with the model that gave it and what was sent (AI-02 to AI-04).
public struct AIAnswer: Hashable, Sendable {
    /// "Why Did It Fail?"'s answer
    public var explanation: BuildExplanation?
    /// "Summarize Discussion"'s answer
    public var summary: ThreadsSummary?
    /// the digest's text
    public var text: String?
    /// the model that answered, like `claude-opus-5-5`
    public var model: String
    /// what was sent
    public var prompt: ClaudePrompt
    public var answeredAt: Date

    public init(
        explanation: BuildExplanation? = nil, summary: ThreadsSummary? = nil, text: String? = nil, model: String,
        prompt: ClaudePrompt, answeredAt: Date
    ) {
        self.explanation = explanation
        self.summary = summary
        self.text = text
        self.model = model
        self.prompt = prompt
        self.answeredAt = answeredAt
    }

    /// the model that answered, for the card: "Opus 5.5", or the name as reported when it is none of the app's
    public var modelName: String {
        ClaudeModel(rawValue: model)?.shortName ?? model
    }
}

/// Where an AI answer stands.
public enum AIAnswerState: Hashable, Sendable {
    /// nothing asked
    case idle
    /// the facts are being gathered: the failed tests and the console log, the threads
    case preparing
    /// the first send of a use case: what will be sent shows, and waits for Send
    case review(ClaudePrompt)
    /// Claude is answering
    case running(ClaudePrompt)
    case answered(AIAnswer)
    /// why there is no answer, and what was sent, if anything
    case failed(String, ClaudePrompt?)
}

/// The Claude features (the plan's Phase 15, AI-01 to AI-06): "Why Did It Fail?", "Summarize Discussion", the daily
/// digest, and "Open in Claude Code", through the developer's own Claude Code (`claude`).
///
/// The rules it keeps:
/// - off by default, one switch in Settings → General; hidden entirely while `claude` isn't installed;
/// - nothing is sent without a click, except the morning digest the user turns on; the first send of each use case shows
///   what it sends and waits for Send;
/// - everything sent is redacted first (``SecretRedactor``): the app's tokens, cookies, keys and passwords never go out;
/// - the answer is marked as Claude's; a failure stays plainly a failure;
/// - the log gets the use case, the model, the tokens and the exit code, never the prompt or the answer.
@Observable @MainActor
public final class AIStore {
    /// how long `open -a <terminal>` may take
    static let launchWait: Duration = .seconds(10)

    public private(set) var settings: AISettings
    public private(set) var availability: ClaudeAvailability = .unknown
    /// each subject's answer
    public private(set) var states: [AISubject: AIAnswerState] = [:]
    /// what the last Open in Claude Code did, or why it failed, and for what; replaced by the next
    public private(set) var lastLaunch: ClaudeCodeLaunchResult?
    /// what the next question of a merge request's chat is about, by its reference: a removable chip above the field;
    /// none means the whole merge request (AI-07)
    public internal(set) var pendingScopes: [String: CodeScope] = [:]
    /// counts the times a scope was aimed at, so that the chat's field can take the focus when it is
    public internal(set) var aimCount = 0
    /// what the first question of a subject's chat was about (AI-07)
    public internal(set) var openingScopes: [AISubject: CodeScope] = [:]
    /// the subjects whose run the user stopped; their card says so until the next question or Clear
    public internal(set) var stoppedSubjects: Set<AISubject> = []
    /// the question of a stopped first answer, for the field to take back once
    var stoppedQuestions: [AISubject: String] = [:]
    /// the follow-up questions and answers below each subject's answer, while the app runs (AI-08)
    public internal(set) var conversations: [AISubject: Conversation] = [:]
    /// the user's own first question of the subjects that start with one, like a work item's (AI-08)
    public internal(set) var openingQuestions: [AISubject: String] = [:]

    /// what the user's Claude Code setup offers the chats, once per app session (AI-09)
    public internal(set) var setupInventory: SetupInventoryState = .unknown
    /// the user's slash commands and skills for the "/" list; empty until read
    public internal(set) var slashCommands: [SlashCommand] = []

    /// posts the morning digest as a notification, with its text; the app sets it
    @ObservationIgnored public var notify: (@Sendable (String) async -> Void)?
    /// loads the merge requests and work items before the digest is written; the app sets it
    @ObservationIgnored public var refreshBeforeDigest: (@MainActor () async -> Void)?
    /// the digest's facts from the app's stores; the app sets it
    @ObservationIgnored public var digestFacts: (@MainActor () -> DigestFacts)?

    /// the model chosen for an answer that waits in review, until it is sent
    @ObservationIgnored private var reviewModels: [AISubject: ClaudeModel] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let engine: ClaudeEngine
    @ObservationIgnored private let launcher: any ProgramLauncher
    @ObservationIgnored private let terminals: any TerminalDirectory
    @ObservationIgnored private let launchFolder: URL
    @ObservationIgnored private let log: ActivityLog?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored private let jenkins: PipelinesServices?
    @ObservationIgnored let gitLab: GitLabServices?
    /// runs `git` to read a checkout's commit for a question about code
    @ObservationIgnored let runner: any ProcessRunner
    /// gathers the diff a follow-up of a code chat is about, by subject; the latest question's facts
    @ObservationIgnored var scopeContexts: [AISubject: @Sendable (CodeScope) async throws -> String] = [:]
    /// the first answers being gathered or written, by subject, with where the subject stood before, so that Stop can end
    /// them and put the card back
    @ObservationIgnored var runs: [AISubject: FirstRun] = [:]
    /// the follow-ups being answered, by subject, so that Stop can end them
    @ObservationIgnored var followUpTasks: [AISubject: Task<Void, Never>] = [:]
    /// the subjects with a conversation, the oldest first
    @ObservationIgnored var conversationOrder: [AISubject] = []
    @ObservationIgnored private var detecting: Task<Void, Never>?
    /// the setup listing in progress, so that two chats waiting for it share one
    @ObservationIgnored var listing: Task<Void, Never>?
    /// the folder the slash commands were read for
    @ObservationIgnored var slashCommandsProject: String??
    @ObservationIgnored private var digestLoop: Task<Void, Never>?

    /// - Parameters:
    ///   - defaults: the preferences' suite, where the settings are kept
    ///   - runner: runs `claude` and the login shell
    ///   - launcher: opens the terminal for Open in Claude Code
    ///   - terminals: where the user's terminal is looked up
    ///   - launchFolder: where Open in Claude Code's launch folders go
    ///   - log: the Activity log
    ///   - clock: the clock of the morning digest
    ///   - now: the current time
    ///   - jenkins: the Jenkins services, for a failed build's log, changes and tests
    ///   - gitLab: the GitLab services, for a merge request's threads
    ///   - resolver: finds `claude`; one of its own by default
    public init(
        defaults: UserDefaults, runner: any ProcessRunner, launcher: any ProgramLauncher = SystemProgramLauncher(),
        terminals: any TerminalDirectory = SystemTerminalDirectory(),
        launchFolder: URL = FileManager.default.temporaryDirectory.appending(path: "menubar-monitor-claude", directoryHint: .isDirectory),
        log: ActivityLog? = nil, clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() },
        jenkins: PipelinesServices? = nil, gitLab: GitLabServices? = nil, resolver: ProgramResolver? = nil
    ) {
        self.defaults = defaults
        self.runner = runner
        engine = ClaudeEngine(runner: runner, resolver: resolver)
        self.launcher = launcher
        self.terminals = terminals
        self.launchFolder = launchFolder
        self.log = log
        self.clock = clock
        self.now = now
        self.jenkins = jenkins
        self.gitLab = gitLab
        settings = AISettings.load(from: defaults)
        // The monthly spend of earlier versions is gone.
        defaults.removeObject(forKey: "ai.usage")
        scheduleDigest()
    }

    /// whether the Claude features show in the detail views: turned on, and `claude` found
    public var isOffered: Bool {
        settings.isEnabled && availability == .found
    }

    /// whether Settings shows the Claude section: only while `claude` is installed
    public var isSettingsShown: Bool {
        availability == .found
    }

    /// Looks for `claude` once, so the Claude features show or stay hidden. Calling it again waits for the first look.
    public func detect() async {
        if detecting == nil {
            let engine = engine
            detecting = Task { [weak self] in
                let found = await engine.locate() != nil
                self?.availability = found ? .found : .missing
            }
        }
        await detecting?.value
    }

    /// Looks for `claude` again, as after installing it.
    public func detectAgain() async {
        await engine.forgetLocation()
        detecting = nil
        await detect()
    }

    /// Saves changed settings. Logs what changed: on or off, the model, the effort, the digest; never anything sent.
    ///
    /// - Parameter new: the settings as edited
    public func update(_ new: AISettings) {
        guard new != settings else {
            return
        }
        let old = settings
        settings = new
        new.save(to: defaults)
        if old.isEnabled != new.isEnabled {
            record(new.isEnabled ? "Claude is on, with \(new.model.title)" : "Claude is off", level: .info, source: .settings)
        } else if old.model != new.model {
            record("Claude answers with \(new.model.title)", level: .info, source: .settings)
        }
        if old.effort != new.effort {
            record("Claude's effort is \(new.effort.title)", level: .info, source: .settings)
        }
        if old.useMySetup != new.useMySetup {
            record(new.useMySetup ? "Claude chats use your Claude Code setup" : "Claude chats are back in safe mode", level: .info, source: .settings)
        }
        if old.useMyClaudeMd != new.useMyClaudeMd {
            record(new.useMyClaudeMd ? "Claude chats read your CLAUDE.md" : "Claude chats leave your CLAUDE.md out", level: .info, source: .settings)
        }
        if old.morningDigest != new.morningDigest || old.digestMinutes != new.digestMinutes || old.isEnabled != new.isEnabled {
            if new.morningDigest != old.morningDigest {
                record(new.morningDigest ? "The morning digest is on" : "The morning digest is off", level: .info, source: .settings)
            }
            scheduleDigest()
        }
    }

    /// Returns where a subject's answer stands.
    public func state(of subject: AISubject) -> AIAnswerState {
        states[subject] ?? .idle
    }

    /// Forgets a subject's answer or failure, or cancels its review.
    public func dismiss(_ subject: AISubject) {
        states[subject] = nil
        reviewModels[subject] = nil
        clearConversation(of: subject)
        openingQuestions[subject] = nil
        openingScopes[subject] = nil
        scopeContexts[subject] = nil
        stoppedSubjects.remove(subject)
        stoppedQuestions[subject] = nil
    }

    // MARK: - The use cases

    /// "Why Did It Fail?" (AI-02): gathers the failed tests, the log narrowed to its error markers and the commits since
    /// the last green build from Jenkins (``BuildFailureFacts/gather(_:failedTests:flakyHints:client:)``), adds the
    /// failed stages and their history, and asks Claude for the root cause, the evidence, the suspect commits, real or
    /// flaky or infrastructure, and the next step.
    ///
    /// - Parameters:
    ///   - build: the failed build
    ///   - failedTests: the failed tests when the detail has them; read from Jenkins otherwise
    ///   - flakyHints: what the job's recent builds say of the failed stages, when the detail has it
    ///   - model: the model for this answer; `nil` is the one chosen in Settings
    public func explain(_ build: Build, failedTests: [FailedTest]?, flakyHints: [FlakyHint] = [], model: ClaudeModel? = nil) async {
        await ask(.build(build.id), model: model) { [jenkins] in
            guard let jenkins else {
                throw AIGatherError("Jenkins isn't set up")
            }
            let facts = try await Self.buildFacts(build, failedTests: failedTests, flakyHints: flakyHints, services: jenkins)
            return .explainBuild(facts)
        }
    }

    /// "Summarize Discussion" (AI-03): reads the merge request's threads with all their notes from GitLab, and asks
    /// Claude what was agreed, what is open, and who each open point waits on.
    ///
    /// - Parameters:
    ///   - mergeRequest: the merge request
    ///   - model: the model for this answer; `nil` is the one chosen in Settings
    public func summarize(_ mergeRequest: MergeRequest, model: ClaudeModel? = nil) async {
        await ask(.mergeRequest(mergeRequest.reference), model: model) { [gitLab] in
            guard let gitLab else {
                throw AIGatherError("GitLab isn't set up")
            }
            guard let operation = GitLabOperation.threadText(of: DescriptionSource(mergeRequest)) else {
                throw AIGatherError("The merge request's reference can't be read")
            }
            let session: GitLabSession
            switch await gitLab.session() {
            case .success(let found): session = found
            case .failure(let error): throw AIGatherError(error.problem.message)
            }
            let threads: [DiscussionThread]
            do {
                threads = try await session.client.send(operation)
            } catch let error as GitLabError {
                throw AIGatherError("Couldn't read the threads: \(error.problem.message)")
            }
            guard !threads.isEmpty else {
                throw AIGatherError("The merge request has no review threads to summarize")
            }
            return .summarizeThreads(
                ThreadsFacts(
                    reference: mergeRequest.reference, title: mergeRequest.title, author: mergeRequest.author,
                    threads: threads))
        }
    }

    /// The daily digest (AI-04): loads the merge requests and work items, gathers my merge requests, the reviews
    /// waiting for me, the red builds and the work items by slot from the app's stores, and asks Claude for a short
    /// text.
    ///
    /// - Parameter model: the model for this answer; `nil` is the one chosen in Settings
    public func writeDigest(model: ClaudeModel? = nil) async {
        await ask(.digest, model: model) { [weak self] in
            await self?.refreshBeforeDigest?()
            guard let facts = self?.digestFacts?() else {
                throw AIGatherError("Nothing to write about yet")
            }
            guard !facts.isEmpty else {
                throw AIGatherError("No merge requests, builds or work items to write about yet")
            }
            return .digest(facts)
        }
    }

    /// Sends a prompt that waits in review, and remembers that its use case was shown once.
    ///
    /// - Parameter subject: the subject whose prompt shows
    public func send(_ subject: AISubject) async {
        guard case .review(let prompt) = state(of: subject) else {
            return
        }
        var next = settings
        next.confirmedUseCases.insert(prompt.useCase)
        update(next)
        let model = reviewModels[subject]
        await track(subject) { await self.run(subject, prompt, model: model) }
    }

    /// Asks again with what was sent before, to another model: the answer's own facts, not gathered anew. Works on an
    /// answer and on a failure that had sent something; nothing else.
    ///
    /// - Parameters:
    ///   - subject: the subject whose answer is asked for again
    ///   - model: the model for this answer
    public func askAgain(_ subject: AISubject, model: ClaudeModel) async {
        let prompt: ClaudePrompt
        switch state(of: subject) {
        case .answered(let answer): prompt = answer.prompt
        case .failed(_, let sent?): prompt = sent
        default: return
        }
        guard settings.isEnabled else {
            return
        }
        await track(subject) { await self.run(subject, prompt, model: model) }
    }

    /// Opens the user's terminal in a checkout running `claude` with the context as its first prompt (AI-05;
    /// ``ClaudeCodeLaunch``): the terminal chosen in Settings → Repositories, else the one that opens `.command` files,
    /// and Terminal, said in the result, when that one can't run a script (``TerminalChoice``).
    ///
    /// - Parameters:
    ///   - context: the work item, merge request, build or checkout
    ///   - checkout: the checkout Claude Code starts in
    ///   - model: the model Claude Code starts with; `nil` is the one chosen in Settings
    public func openInClaudeCode(_ context: ClaudeCodeContext, in checkout: Checkout, model: ClaudeModel? = nil) async {
        lastLaunch = nil
        guard settings.isEnabled, let claude = await engine.locate() else {
            lastLaunch = ClaudeCodeLaunchResult(context: context, message: ClaudeFailure.notFound.message, isProblem: true)
            return
        }
        let prompt = SecretRedactor(knownSecrets: await knownSecrets()).redact(context.prompt(in: checkout))
        ClaudeCodeLaunch.removeLeftovers(in: launchFolder, now: now())
        let choice = TerminalChoice.choose(preferred: TerminalChoice.preferred(in: defaults), for: .script, in: terminals)
        do {
            let script = try ClaudeCodeLaunch.write(
                prompt: prompt, directory: checkout.path, claude: claude, model: model ?? settings.model,
                effort: settings.effort, in: launchFolder)
            let outcome = try await launcher.launch(
                URL(filePath: "/usr/bin/open"), arguments: choice.openArguments(for: script.path(percentEncoded: false)),
                directory: nil, path: nil, wait: Self.launchWait)
            switch outcome {
            case .exited(status: 0, _), .running:
                lastLaunch = ClaudeCodeLaunchResult(
                    context: context, message: "Claude Code starts in \(checkout.name), in \(choice.summary)", isProblem: false)
                record("Claude: \(AIUseCase.openInClaudeCode.logName) in \(checkout.name), exit 0", level: .info, source: .app)
            case .exited(let status, let lastLine):
                lastLaunch = ClaudeCodeLaunchResult(
                    context: context, message: lastLine ?? "open ended with \(status)", isProblem: true)
                record("Claude: \(AIUseCase.openInClaudeCode.logName) in \(checkout.name), exit \(status)", level: .warning, source: .app)
            }
        } catch {
            lastLaunch = ClaudeCodeLaunchResult(
                context: context, message: "Couldn't open \(choice.app.name): \(error.localizedDescription)", isProblem: true)
            record("Claude: \(AIUseCase.openInClaudeCode.logName) couldn't start", level: .warning, source: .app)
        }
    }

    // MARK: - Asking

    /// Gathers the facts, redacts them, and sends them, or first shows them when the use case was never sent. The user
    /// can stop it meanwhile (``stop(_:)``).
    func ask(
        _ subject: AISubject, model: ClaudeModel?, prompt make: @escaping @MainActor () async throws -> ClaudePrompt
    ) async {
        switch state(of: subject) {
        case .preparing, .running:
            return
        default:
            break
        }
        guard settings.isEnabled else {
            return
        }
        await track(subject) { await self.gatherAndRun(subject, model: model, prompt: make) }
    }

    private func gatherAndRun(
        _ subject: AISubject, model: ClaudeModel?, prompt make: @escaping @MainActor () async throws -> ClaudePrompt
    ) async {
        await detect()
        guard isOffered else {
            states[subject] = .failed(ClaudeFailure.notFound.message, nil)
            return
        }
        states[subject] = .preparing
        let prompt: ClaudePrompt
        do {
            prompt = try await make().redacted(by: SecretRedactor(knownSecrets: await knownSecrets()))
        } catch let error as AIGatherError {
            guard !Task.isCancelled else { return }
            states[subject] = .failed(error.message, nil)
            return
        } catch let error as JenkinsError {
            guard !Task.isCancelled else { return }
            states[subject] = .failed(error.problem.message, nil)
            return
        } catch {
            guard !Task.isCancelled else { return }
            states[subject] = .failed(error.localizedDescription, nil)
            return
        }
        guard !Task.isCancelled else { return }
        guard settings.confirmedUseCases.contains(prompt.useCase) else {
            states[subject] = .review(prompt)
            reviewModels[subject] = model
            return
        }
        await run(subject, prompt, model: model)
    }

    /// Runs a first answer's work as a task Stop can end, and keeps where the subject stood before.
    private func track(_ subject: AISubject, _ work: @escaping @MainActor () async -> Void) async {
        stoppedSubjects.remove(subject)
        stoppedQuestions[subject] = nil
        let task = Task { await work() }
        runs[subject] = FirstRun(task: task, before: states[subject])
        await task.value
        if runs[subject]?.task == task {
            runs[subject] = nil
        }
    }

    /// Stops a first answer that is being gathered or written: `claude` is ended, the card goes back to where it was
    /// before the question (nothing, or the review, or the earlier answer) with "Stopped", and no failure is shown.
    /// A question of the user's own comes back to its field.
    ///
    /// - Parameter subject: the subject
    /// - Returns: whether something was stopped
    @discardableResult
    public func stop(_ subject: AISubject) -> Bool {
        switch state(of: subject) {
        case .preparing, .running: break
        default: return false
        }
        guard let run = runs[subject] else {
            return false
        }
        run.task.cancel()
        runs[subject] = nil
        states[subject] = run.before
        if run.before == nil {
            // The chat's question goes back to the field, with its scope.
            if let question = openingQuestions[subject] {
                stoppedQuestions[subject] = question
                if case .codeChat(let reference) = subject, let scope = openingScopes[subject], scope != .mergeRequest {
                    pendingScopes[reference] = scope
                }
            }
            openingQuestions[subject] = nil
            openingScopes[subject] = nil
        }
        stoppedSubjects.insert(subject)
        return true
    }

    /// Returns the question of a stopped first answer once, for the field to take back.
    ///
    /// - Parameter subject: the subject
    public func takeStoppedQuestion(of subject: AISubject) -> String? {
        stoppedQuestions.removeValue(forKey: subject)
    }

    /// Sends a prompt, and keeps the answer and the log line.
    private func run(_ subject: AISubject, _ prompt: ClaudePrompt, model chosen: ClaudeModel?) async {
        reviewModels[subject] = nil
        states[subject] = .running(prompt)
        let model = chosen ?? settings.model
        do {
            let setup = await setupForChat(of: prompt)
            let run = try await engine.run(
                setup == nil ? prompt : prompt.startingWithCommand(), model: model, effort: settings.effort, setup: setup)
            guard !Task.isCancelled else { return }
            // A new first answer starts the conversation anew.
            clearConversation(of: subject)
            count(run, prompt: prompt, model: model)
            guard let answer = Self.answer(of: run, prompt: prompt, model: model, at: now()) else {
                states[subject] = .failed(ClaudeFailure.unreadableAnswer(run).message, prompt)
                return
            }
            states[subject] = .answered(answer)
        } catch {
            guard !Task.isCancelled else { return }
            clearConversation(of: subject)
            if let run = error.run {
                count(run, prompt: prompt, model: model)
            } else {
                let status = if case .failed(let status, _) = error { "exit \(status)" } else { "no answer" }
                record("Claude: \(prompt.useCase.logName) failed, \(status)", level: .warning, source: .app)
            }
            states[subject] = .failed(error.message, prompt)
        }
    }

    /// Returns the answer of a run in the shape of its use case; `nil` when the structured answer is missing.
    static func answer(of run: ClaudeRun, prompt: ClaudePrompt, model: ClaudeModel, at date: Date) -> AIAnswer? {
        var answer = AIAnswer(
            model: run.model ?? model.rawValue, prompt: prompt, answeredAt: date)
        switch prompt.useCase {
        case .explainBuild:
            guard let explanation = run.decoded(BuildExplanation.self) else { return nil }
            answer.explanation = explanation.keepingEvidence(in: prompt.text)
        case .summarizeThreads:
            guard let summary = run.decoded(ThreadsSummary.self) else { return nil }
            answer.summary = summary
        case .digest, .openInClaudeCode, .askAboutCode, .askAboutItem:
            guard let text = run.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            answer.text = text
        }
        return answer
    }

    /// Logs a run: the use case, the model, the tokens and the exit code.
    func count(_ run: ClaudeRun, prompt: ClaudePrompt, model: ClaudeModel, followUp: Bool = false) {
        let line = "Claude: \(prompt.useCase.logName)\(followUp ? " follow-up" : ""), \(run.model ?? model.rawValue), "
            + "\(run.usage.inputTokens) tokens in, \(run.usage.outputTokens) out, exit \(run.exitStatus)"
        // A stopped call reads in plain words, not as the raw `error_max_budget_usd` code.
        let reason = run.subtype == "error_max_budget_usd" ? "stopped before it finished" : run.subtype ?? "error"
        record(run.isError ? line + ", \(reason)" : line, level: run.isError ? .warning : .info, source: .app)
    }

    /// The app's tokens, which the redactor removes wherever they appear.
    func knownSecrets() async -> [String] {
        guard let tokens = jenkins?.tokens ?? gitLab?.tokens else {
            return []
        }
        var secrets: [String] = []
        for account in TokenAccount.allCases {
            if let token = try? await tokens.token(account), !token.isEmpty {
                secrets.append(token)
            }
        }
        return secrets
    }

    /// Reads what a failed build tells from Jenkins, with the client of the build's project.
    private nonisolated static func buildFacts(
        _ build: Build, failedTests: [FailedTest]?, flakyHints: [FlakyHint], services: PipelinesServices
    ) async throws -> BuildFailureFacts {
        let project = services.team.project(build.project) ?? services.team.primaryProject()
        let token = await services.token(.jenkins)
        let client = try JenkinsClient.make(
            project: project, token: token, transport: services.recorder(for: project), timeouts: services.timeouts
        ).get()
        return try await BuildFailureFacts.gather(build, failedTests: failedTests, flakyHints: flakyHints, client: client)
    }

    // MARK: - The morning digest

    /// Returns the next time the morning digest is written: today at its time, or tomorrow when that has passed.
    ///
    /// - Parameters:
    ///   - date: now
    ///   - minutes: the time, in minutes after midnight
    ///   - calendar: the calendar, local time
    /// - Returns: the time
    nonisolated public static func nextDigest(after date: Date, minutes: Int, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        let today = calendar.date(byAdding: .minute, value: minutes, to: start) ?? date
        if today > date {
            return today
        }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    }

    /// Starts or stops the wait for the morning digest, as the settings say.
    private func scheduleDigest() {
        digestLoop?.cancel()
        digestLoop = nil
        guard settings.isEnabled, settings.morningDigest else {
            return
        }
        let clock = clock
        digestLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.delayUntilDigest() else {
                    return
                }
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    return
                }
                await self?.writeMorningDigest()
            }
        }
    }

    private func delayUntilDigest() -> Duration {
        let date = now()
        let next = Self.nextDigest(after: date, minutes: settings.digestMinutes)
        return .seconds(max(next.timeIntervalSince(date), 1))
    }

    /// Writes the digest the user scheduled, without a click, and posts it. A Mac that slept through the time writes it
    /// at wake only within three hours of it.
    private func writeMorningDigest() async {
        let date = now()
        let scheduled = Self.nextDigest(after: date.addingTimeInterval(-86_400), minutes: settings.digestMinutes)
        guard date.timeIntervalSince(scheduled) < 3 * 3600 else {
            return
        }
        await detect()
        guard isOffered, settings.morningDigest else {
            return
        }
        var next = settings
        next.confirmedUseCases.insert(.digest)
        update(next)
        await writeDigest()
        if case .answered(let answer) = state(of: .digest), let text = answer.text {
            await notify?(text)
        }
    }

    func record(_ message: String, level: ActivityEntry.Level, source: ActivityEntry.Source) {
        guard let log else {
            return
        }
        Task { await log.log(level, source, message) }
    }
}

/// What an Open in Claude Code did, or why it failed, for the detail it was clicked in.
public struct ClaudeCodeLaunchResult: Hashable, Sendable {
    public var context: ClaudeCodeContext
    public var message: String
    public var isProblem: Bool

    public init(context: ClaudeCodeContext, message: String, isProblem: Bool) {
        self.context = context
        self.message = message
        self.isProblem = isProblem
    }
}

/// Why the facts for Claude couldn't be gathered, in words for the card.
struct AIGatherError: Error {
    var message: String

    init(_ message: String) {
        self.message = message
    }
}
