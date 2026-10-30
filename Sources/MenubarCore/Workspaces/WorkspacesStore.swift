import Foundation
import Observation

/// The Workspaces section's state (WS-01 to WS-05): the settings of Settings → Repositories, the checkouts found with
/// them, what git says of each, and the actions on a checkout.
///
/// It reads the checkouts only while something shows them: when the Workspaces section or Settings → Repositories
/// appears, then every ``refreshInterval`` while one shows; Check Now reads them again. The reads run one checkout after
/// the other, off the main actor, read-only (``GitReader``). The log gets checkout names, branch names and counts only,
/// never a path, a file name or a command's environment.
@Observable @MainActor
public final class WorkspacesStore {
    /// how often the checkouts are read again while they show
    public static let refreshInterval: Duration = .seconds(180)
    /// how old a reading may be when the section shows again before it is read again
    public static let freshness: TimeInterval = 20
    /// how long an action's program may run before the app stops waiting for it
    public static let launchWait: Duration = .seconds(10)

    /// the settings of Settings → Repositories
    public private(set) var settings: RepositorySettings
    /// what each Settings entry found, in the entries' order; empty until the first read
    public private(set) var findings: [FolderFindings] = []
    /// each checkout's state as last read, by its path
    public private(set) var readings: [Checkout.ID: CheckoutReading] = [:]
    /// whether a read runs
    public private(set) var isRefreshing = false
    /// when the last read ended; `nil` before the first
    public private(set) var lastRefreshAt: Date?
    /// why an action on a checkout failed, like the IDE command's last output line, by the checkout's path; cleared by
    /// its next action
    public private(set) var actionProblems: [Checkout.ID: String] = [:]
    /// the checkouts whose Open in IDE runs right now
    public private(set) var openingInIDE: Set<Checkout.ID> = []
    /// each checkout's local branches as last read, by its path; read when its detail shows (WS-06)
    public private(set) var branchReadings: [Checkout.ID: LocalBranchesReading] = [:]
    /// the terminal chosen in Settings → Repositories, by bundle identifier; `nil` is Default
    public private(set) var terminal: String?
    /// the checkouts whose Start Work Here runs right now (WS-08)
    public private(set) var startingWork: Set<Checkout.ID> = []
    /// what the last Start Work Here did, like "Started 1234-fix-login", by the checkout's path; cleared by the
    /// checkout's next action
    public private(set) var actionNotes: [Checkout.ID: String] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let reader: GitReader
    @ObservationIgnored private let runner: any ProcessRunner
    @ObservationIgnored private let resolver: ProgramResolver
    @ObservationIgnored private let launcher: any ProgramLauncher
    @ObservationIgnored private let terminals: any TerminalDirectory
    @ObservationIgnored private let log: ActivityLog?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let home: URL
    @ObservationIgnored private var hosts: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// whether one more read follows the running one, because something changed while it ran
    @ObservationIgnored private var refreshAgain = false

    /// - Parameters:
    ///   - defaults: the preferences' suite, where Settings → Repositories is kept
    ///   - runner: runs `git` and the login shell
    ///   - launcher: starts the actions' programs
    ///   - terminals: where Open in Terminal's app is looked up
    ///   - log: the Activity log
    ///   - clock: the clock of the reads every few minutes
    ///   - now: the current time
    ///   - home: the home folder, for `~`
    public init(
        defaults: UserDefaults, runner: any ProcessRunner, launcher: any ProgramLauncher = SystemProgramLauncher(),
        terminals: any TerminalDirectory = SystemTerminalDirectory(),
        log: ActivityLog? = nil, clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() },
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.defaults = defaults
        reader = GitReader(runner: runner)
        self.runner = runner
        resolver = ProgramResolver(runner: runner, home: home)
        self.launcher = launcher
        self.terminals = terminals
        self.log = log
        self.clock = clock
        self.now = now
        self.home = home
        settings = RepositorySettings.load(from: defaults)
        terminal = TerminalChoice.preferred(in: defaults)
    }

    /// every checkout found, in the entries' order
    public var checkouts: [Checkout] {
        findings.flatMap(\.checkouts)
    }

    /// whether Settings → Repositories has a folder
    public var hasFolders: Bool {
        !settings.folders.isEmpty
    }

    // MARK: - Settings

    /// Saves changed settings and reads the checkouts again. Logs which part changed, never a path or the command's
    /// arguments.
    ///
    /// - Parameter new: the settings as edited
    public func update(_ new: RepositorySettings) {
        guard new != settings else {
            return
        }
        let old = settings
        settings = new
        new.save(to: defaults)
        if old.folders != new.folders {
            let count = new.folders.count
            log("Repositories: \(count) folder\(count == 1 ? "" : "s")", level: .info, source: .settings)
            refresh()
        }
        if old.ideCommand != new.ideCommand {
            let program = LaunchCommand.words(of: new.ideCommand)?.first.map { ($0 as NSString).lastPathComponent }
            log(program.map { "Open in IDE runs \($0)" } ?? "Open in IDE is off", level: .info, source: .settings)
        }
    }

    /// Keeps the terminal Open in Terminal and Open in Claude Code use.
    ///
    /// - Parameter id: the terminal's bundle identifier; `nil` for Default
    public func setTerminal(_ id: String?) {
        guard id != terminal else {
            return
        }
        terminal = id
        TerminalChoice.setPreferred(id, in: defaults)
        let name = id.flatMap { terminals.app(bundleID: $0)?.name }
        log("Terminal: \(name ?? "Default")", level: .info, source: .settings)
    }

    /// Returns what Settings → Repositories offers as the terminal: the default and the installed terminals.
    public func terminalOptions() -> (default: TerminalApp?, installed: [TerminalApp]) {
        (terminals.scriptHandler(), terminals.installedTerminals())
    }

    /// Returns the folder or pattern to add for a folder picked with Add Folder… (``WorkspaceDiscovery/suggestedPath(for:home:fileManager:)``).
    ///
    /// - Parameter folder: the picked folder
    /// - Returns: the entry's path, `~` for the home folder
    public func suggestedPath(for folder: URL) async -> String {
        let home = home
        return await Task.detached(priority: .userInitiated) {
            WorkspaceDiscovery.suggestedPath(for: folder.path(percentEncoded: false), home: home)
        }.value
    }

    /// Returns the Open in IDE program's full path, for Settings to show; `nil` when it isn't found.
    ///
    /// - Parameter program: the program as typed
    public func resolve(_ program: String) async -> URL? {
        await resolver.resolve(program)
    }

    /// the home folder, for Settings to show paths with `~`
    public var homeFolder: URL { home }

    // MARK: - Reading the checkouts

    /// Notes that a view shows the checkouts: the first one reads them, unless the last read is fresh, and starts the
    /// reads every ``refreshInterval``.
    ///
    /// - Parameter host: the view's name, like `workspaces`
    public func show(by host: String) {
        let wasShown = !hosts.isEmpty
        hosts.insert(host)
        guard !wasShown else {
            return
        }
        if lastRefreshAt.map({ now().timeIntervalSince($0) >= Self.freshness }) ?? true {
            refresh()
        }
        let clock = clock
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
                self?.refresh()
            }
        }
    }

    /// Notes that a view no longer shows the checkouts; with none left, the reads every few minutes stop.
    ///
    /// - Parameter host: the view's name
    public func hide(by host: String) {
        hosts.remove(host)
        if hosts.isEmpty {
            loop?.cancel()
            loop = nil
        }
    }

    /// whether a view shows the checkouts
    public var isShown: Bool {
        !hosts.isEmpty
    }

    /// Reads the checkouts again while a view shows them, as Check Now does.
    public func refreshIfShown() {
        if isShown {
            refresh()
        }
    }

    /// Finds the checkouts and reads each with git, one after the other. A read during a read runs once more after it.
    public func refresh() {
        guard refreshTask == nil else {
            refreshAgain = true
            return
        }
        refreshTask = Task { [weak self] in
            await self?.runRefreshes()
        }
    }

    /// Waits until the reads under way have ended, for the tests.
    public func settled() async {
        await refreshTask?.value
    }

    private func runRefreshes() async {
        isRefreshing = true
        repeat {
            refreshAgain = false
            await refreshOnce()
        } while refreshAgain
        isRefreshing = false
        lastRefreshAt = now()
        refreshTask = nil
    }

    private func refreshOnce() async {
        let folders = settings.folders
        let home = home
        let found = await Task.detached(priority: .utility) {
            WorkspaceDiscovery.find(folders, home: home)
        }.value
        findings = found
        let paths = Set(found.flatMap(\.checkouts).map(\.id))
        readings = readings.filter { paths.contains($0.key) }
        for checkout in found.flatMap(\.checkouts) {
            let reading = await reader.read(checkout)
            if case .failed = reading, readings[checkout.id] != reading {
                log("Couldn't read the checkout \(checkout.name) with git", level: .warning, source: .app)
            }
            readings[checkout.id] = reading
        }
    }

    // MARK: - Actions

    /// Opens the checkout with the user's Open in IDE command: the program found once, the placeholders replaced, no
    /// shell (WS-05). A failure shows the program's last output line; the log gets the program's name and exit code.
    ///
    /// - Parameter checkout: the checkout
    public func openInIDE(_ checkout: Checkout) async {
        actionProblems[checkout.id] = nil
        actionNotes[checkout.id] = nil
        guard let command = LaunchCommand.make(settings.ideCommand, name: checkout.name, path: checkout.path) else {
            actionProblems[checkout.id] = "Set the Open in IDE command in Settings → Repositories"
            return
        }
        guard let program = await resolver.resolve(command.program) else {
            let name = (command.program as NSString).lastPathComponent
            actionProblems[checkout.id] = "Couldn't find \(name): enter its full path in Settings → Repositories"
            log("Open in IDE: couldn't find \(name)", level: .warning, source: .app)
            return
        }
        openingInIDE.insert(checkout.id)
        defer { openingInIDE.remove(checkout.id) }
        let path = await resolver.searchPath()
        await launch(program, arguments: command.arguments, in: checkout, path: path, action: "Open in IDE")
    }

    /// Opens the checkout in the user's terminal: `open -a <app> <path>`, with the terminal chosen in Settings →
    /// Repositories, else the one that opens `.command` files, and Terminal with a note when that one can't open a
    /// folder (``TerminalChoice``).
    ///
    /// - Parameter checkout: the checkout
    public func openInTerminal(_ checkout: Checkout) async {
        actionProblems[checkout.id] = nil
        actionNotes[checkout.id] = nil
        let choice = TerminalChoice.choose(preferred: terminal, for: .folder, in: terminals)
        if let note = choice.note {
            actionNotes[checkout.id] = "Opened in \(choice.app.name): \(note)"
            log("Open in Terminal: \(choice.summary)", level: .info, source: .app)
        }
        await launch(
            URL(filePath: "/usr/bin/open"), arguments: choice.openArguments(for: checkout.path), in: checkout, path: nil,
            action: "Open in Terminal")
    }

    /// Shows the checkout in Finder: `open -R <path>`.
    ///
    /// - Parameter checkout: the checkout
    public func revealInFinder(_ checkout: Checkout) async {
        actionProblems[checkout.id] = nil
        actionNotes[checkout.id] = nil
        await launch(
            URL(filePath: "/usr/bin/open"), arguments: ["-R", checkout.path], in: checkout, path: nil,
            action: "Reveal in Finder")
    }

    // MARK: - Local branches and Start Work Here

    /// Reads a checkout's local branches with git, read-only (WS-06), and keeps them for the detail.
    ///
    /// - Parameter checkout: the checkout
    public func loadBranches(_ checkout: Checkout) async {
        let reading = await reader.readBranches(checkout, now: now())
        guard checkouts.contains(where: { $0.id == checkout.id }) else {
            return
        }
        branchReadings[checkout.id] = reading
    }

    /// Starts work on a work item in a free checkout (WS-08): fetches `origin/<base>`, then starts the item's branch
    /// from it (``WorkStarter``). It writes to the checkout, so it only runs on a click, the guards read the checkout
    /// again right before, and a failure shows git's last output line and changes nothing more. The log gets the
    /// checkout's name, the branch and each step's exit code.
    ///
    /// - Parameters:
    ///   - checkout: the checkout
    ///   - branch: the new branch's name (``BranchSlug/name(number:title:)``)
    /// - Returns: the outcome
    @discardableResult
    public func startWork(in checkout: Checkout, branch: String) async -> StartWorkOutcome {
        guard !startingWork.contains(checkout.id) else {
            return .refused(.unreadable("Start Work Here is running already"))
        }
        actionProblems[checkout.id] = nil
        actionNotes[checkout.id] = nil
        startingWork.insert(checkout.id)
        defer { startingWork.remove(checkout.id) }
        let name = checkout.name
        let steps = StepLog()
        let outcome = await WorkStarter(runner: runner).start(in: checkout, branch: branch) { step, status in
            steps.add("\(step) \(status)")
        }
        switch outcome {
        case .started(let branch):
            actionNotes[checkout.id] = "Started \(branch). Open in IDE is one click away"
            log("Start Work Here: \(name), branch \(branch), exit codes \(steps.text)", level: .info, source: .app)
        case .refused(let refusal):
            actionProblems[checkout.id] = refusal.message
            log("Start Work Here refused in \(name), branch \(branch): \(Self.reason(of: refusal))", level: .warning, source: .app)
        case .fetchFailed, .switchFailed, .couldNotRun:
            actionProblems[checkout.id] = outcome.problem
            log("Start Work Here failed in \(name), branch \(branch), exit codes \(steps.text)", level: .warning, source: .app)
        }
        // The checkout is on its new branch now, or still free: read it again.
        refresh()
        return outcome
    }

    /// the short reason a guard gives, for the log: no file name, no path
    private static func reason(of refusal: StartWorkRefusal) -> String {
        switch refusal {
        case .unreadable: "can't read the checkout"
        case .detached: "detached HEAD"
        case .notOnBase(let branch): "on \(branch)"
        case .dirty(let files): "\(files) changed files"
        case .invalidBase: "invalid base branch"
        case .invalidBranch: "invalid branch name"
        }
    }

    private func launch(
        _ program: URL, arguments: [String], in checkout: Checkout, path: [String]?, action: String
    ) async {
        let name = program.lastPathComponent
        do {
            let outcome = try await launcher.launch(
                program, arguments: arguments, directory: checkout.url, path: path, wait: Self.launchWait)
            switch outcome {
            case .exited(status: 0, _):
                log("\(action): \(name) exited with 0", level: .info, source: .app)
            case .exited(let status, let lastLine):
                actionProblems[checkout.id] = lastLine ?? "\(name) exited with \(status)"
                log("\(action): \(name) exited with \(status)", level: .warning, source: .app)
            case .running:
                log("\(action): \(name) still runs", level: .info, source: .app)
            }
        } catch {
            actionProblems[checkout.id] = "Couldn't start \(name): \(error.localizedDescription)"
            log("\(action): couldn't start \(name)", level: .warning, source: .app)
        }
    }

    private func log(_ message: String, level: ActivityEntry.Level, source: ActivityEntry.Source) {
        guard let log else {
            return
        }
        Task { await log.log(level, source, message) }
    }
}

/// The exit codes of a command sequence, collected from a callback that may run on any thread.
private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []

    func add(_ step: String) {
        lock.withLock { steps.append(step) }
    }

    /// "fetch 0, switch 0", "no git call" before the first
    var text: String {
        lock.withLock { steps.isEmpty ? "no git call" : steps.joined(separator: ", ") }
    }
}
