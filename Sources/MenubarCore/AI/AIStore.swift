import Foundation
import Observation

/// What an AI answer is about: a build, a merge request's discussion, or the digest.
public enum AISubject: Hashable, Sendable {
    case build(BuildID)
    /// a merge request, by its full reference
    case mergeRequest(String)
    case digest
}

/// Whether `claude` is installed, as last looked for.
public enum ClaudeAvailability: Hashable, Sendable {
    case unknown
    case found
    case missing
}

/// An answer of Claude's, with what it cost and what was sent (AI-02 to AI-04).
public struct AIAnswer: Hashable, Sendable {
    /// "Why Did It Fail?"'s answer
    public var explanation: BuildExplanation?
    /// "Summarize Discussion"'s answer
    public var summary: ThreadsSummary?
    /// the digest's text
    public var text: String?
    public var usage: ClaudeUsage
    public var costUSD: Double
    public var seconds: Double?
    /// the model that answered, like `claude-opus-5-5`
    public var model: String
    /// what was sent
    public var prompt: ClaudePrompt
    public var answeredAt: Date

    public init(
        explanation: BuildExplanation? = nil, summary: ThreadsSummary? = nil, text: String? = nil, usage: ClaudeUsage,
        costUSD: Double, seconds: Double?, model: String, prompt: ClaudePrompt, answeredAt: Date
    ) {
        self.explanation = explanation
        self.summary = summary
        self.text = text
        self.usage = usage
        self.costUSD = costUSD
        self.seconds = seconds
        self.model = model
        self.prompt = prompt
        self.answeredAt = answeredAt
    }

    /// "1,407 tokens in, 275 out · $0.017 · 4.5 s"
    public var usageLine: String {
        AIFormat.usageLine(usage, costUSD: costUSD, seconds: seconds)
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
/// - each answer shows its tokens and cost; the month's costs are summed, and at the monthly cap nothing more is sent;
/// - the answer is marked as Claude's; a failure stays plainly a failure;
/// - the log gets the use case, the model, the tokens, the cost and the exit code, never the prompt or the answer.
@Observable @MainActor
public final class AIStore {
    /// how long `open -a <terminal>` may take
    static let launchWait: Duration = .seconds(10)

    public private(set) var settings: AISettings
    /// this month's usage
    public private(set) var usage: AIUsage
    public private(set) var availability: ClaudeAvailability = .unknown
    /// each subject's answer
    public private(set) var states: [AISubject: AIAnswerState] = [:]
    /// what the last Open in Claude Code did, or why it failed, and for what; replaced by the next
    public private(set) var lastLaunch: ClaudeCodeLaunchResult?

    /// posts the morning digest as a notification, with its text; the app sets it
    @ObservationIgnored public var notify: (@Sendable (String) async -> Void)?
    /// loads the merge requests and work items before the digest is written; the app sets it
    @ObservationIgnored public var refreshBeforeDigest: (@MainActor () async -> Void)?
    /// the digest's facts from the app's stores; the app sets it
    @ObservationIgnored public var digestFacts: (@MainActor () -> DigestFacts)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let engine: ClaudeEngine
    @ObservationIgnored private let launcher: any ProgramLauncher
    @ObservationIgnored private let terminals: any TerminalDirectory
    @ObservationIgnored private let launchFolder: URL
    @ObservationIgnored private let log: ActivityLog?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let jenkins: PipelinesServices?
    @ObservationIgnored private let gitLab: GitLabServices?
    @ObservationIgnored private var detecting: Task<Void, Never>?
    @ObservationIgnored private var digestLoop: Task<Void, Never>?

    /// - Parameters:
    ///   - defaults: the preferences' suite, where the settings and the month's usage are kept
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
        usage = AIUsage.load(from: defaults, month: AIUsage.month(of: now()))
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

    /// this month's usage as of now: a new month reads as nothing spent
    public var monthUsage: AIUsage {
        usage.current(in: AIUsage.month(of: now()))
    }

    /// "$0.12 of $10 this month · 7 answers"
    public var monthLine: String {
        let usage = monthUsage
        return "\(AIFormat.cost(usage.costUSD)) of $\(settings.monthlyCapUSD) this month · \(usage.answers) "
            + (usage.answers == 1 ? "answer" : "answers")
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

    /// Saves changed settings. Logs what changed: on or off, the model, the cap, the digest; never anything sent.
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
        if old.monthlyCapUSD != new.monthlyCapUSD {
            record("Claude's monthly cap is $\(new.monthlyCapUSD)", level: .info, source: .settings)
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
    public func explain(_ build: Build, failedTests: [FailedTest]?, flakyHints: [FlakyHint] = []) async {
        await ask(.build(build.id)) { [jenkins] in
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
    /// - Parameter mergeRequest: the merge request
    public func summarize(_ mergeRequest: MergeRequest) async {
        await ask(.mergeRequest(mergeRequest.reference)) { [gitLab] in
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
    public func writeDigest() async {
        await ask(.digest) { [weak self] in
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
        await run(subject, prompt)
    }

    /// Opens the user's terminal in a checkout running `claude` with the context as its first prompt (AI-05;
    /// ``ClaudeCodeLaunch``): the terminal chosen in Settings → Repositories, else the one that opens `.command` files,
    /// and Terminal, said in the result, when that one can't run a script (``TerminalChoice``).
    ///
    /// - Parameters:
    ///   - context: the work item, merge request, build or checkout
    ///   - checkout: the checkout Claude Code starts in
    public func openInClaudeCode(_ context: ClaudeCodeContext, in checkout: Checkout) async {
        lastLaunch = nil
        guard settings.isEnabled, let claude = await engine.locate() else {
            lastLaunch = ClaudeCodeLaunchResult(context: context, message: ClaudeFailure.notFound.message, isProblem: true)
            return
        }
        let prompt = SecretRedactor(knownSecrets: await knownSecrets()).redact(context.prompt(in: checkout))
        ClaudeCodeLaunch.removeLeftovers(in: launchFolder, now: now())
        let choice = TerminalChoice.choose(preferred: TerminalChoice.preferred(in: defaults), for: .script, in: terminals)
        do {
            let script = try ClaudeCodeLaunch.write(prompt: prompt, directory: checkout.path, claude: claude, in: launchFolder)
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

    /// Gathers the facts, redacts them, and sends them, or first shows them when the use case was never sent.
    private func ask(_ subject: AISubject, prompt make: @escaping @MainActor () async throws -> ClaudePrompt) async {
        switch state(of: subject) {
        case .preparing, .running:
            return
        default:
            break
        }
        guard settings.isEnabled else {
            return
        }
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
            states[subject] = .failed(error.message, nil)
            return
        } catch let error as JenkinsError {
            states[subject] = .failed(error.problem.message, nil)
            return
        } catch {
            states[subject] = .failed(error.localizedDescription, nil)
            return
        }
        guard settings.confirmedUseCases.contains(prompt.useCase) else {
            states[subject] = .review(prompt)
            return
        }
        await run(subject, prompt)
    }

    /// Sends a prompt within the monthly cap, and keeps the answer, its cost and the log line.
    private func run(_ subject: AISubject, _ prompt: ClaudePrompt) async {
        let month = AIUsage.month(of: now())
        let budget: Double
        switch AICostCap.allowance(usage: usage.current(in: month), capUSD: settings.monthlyCapUSD) {
        case .reached(let spent, let cap):
            states[subject] = .failed(AICostCap.reachedMessage(spentUSD: spent, capUSD: cap), prompt)
            record("Claude: \(prompt.useCase.logName) not sent: the monthly cap of $\(cap) is reached", level: .warning, source: .app)
            return
        case .allowed(let budgetUSD):
            budget = budgetUSD
        }
        states[subject] = .running(prompt)
        let model = settings.model
        do {
            let run = try await engine.run(prompt, model: model, budgetUSD: budget)
            count(run, prompt: prompt, model: model)
            guard let answer = Self.answer(of: run, prompt: prompt, model: model, at: now()) else {
                states[subject] = .failed(ClaudeFailure.unreadableAnswer(run).message, prompt)
                return
            }
            states[subject] = .answered(answer)
        } catch {
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
            usage: run.usage, costUSD: run.costUSD, seconds: run.durationMS.map { Double($0) / 1000 },
            model: run.model ?? model.rawValue, prompt: prompt, answeredAt: date)
        switch prompt.useCase {
        case .explainBuild:
            guard let explanation = run.decoded(BuildExplanation.self) else { return nil }
            answer.explanation = explanation.keepingEvidence(in: prompt.text)
        case .summarizeThreads:
            guard let summary = run.decoded(ThreadsSummary.self) else { return nil }
            answer.summary = summary
        case .digest, .openInClaudeCode:
            guard let text = run.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            answer.text = text
        }
        return answer
    }

    /// Adds a run's cost to the month and logs it: the use case, the model, the tokens, the cost and the exit code.
    private func count(_ run: ClaudeRun, prompt: ClaudePrompt, model: ClaudeModel) {
        let month = AIUsage.month(of: now())
        usage = usage.adding(costUSD: run.costUSD, usage: run.usage, month: month)
        usage.save(to: defaults)
        let line = "Claude: \(prompt.useCase.logName), \(run.model ?? model.rawValue), "
            + "\(run.usage.inputTokens) tokens in, \(run.usage.outputTokens) out, \(AIFormat.cost(run.costUSD)), exit \(run.exitStatus)"
        record(run.isError ? line + ", \(run.subtype ?? "error")" : line, level: run.isError ? .warning : .info, source: .app)
    }

    /// The app's tokens, which the redactor removes wherever they appear.
    private func knownSecrets() async -> [String] {
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

    private func record(_ message: String, level: ActivityEntry.Level, source: ActivityEntry.Source) {
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
