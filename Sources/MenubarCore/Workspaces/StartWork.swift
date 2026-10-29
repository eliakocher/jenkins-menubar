import Foundation

/// Why "Start Work Here" doesn't run (WS-08).
public enum StartWorkRefusal: Hashable, Sendable {
    /// git couldn't read the checkout, with its problem
    case unreadable(String)
    /// the checkout is at a commit without a branch
    case detached
    /// the checkout is on another branch than its base
    case notOnBase(branch: String)
    /// the checkout has changed or untracked files
    case dirty(files: Int)
    /// the base branch isn't a name the app passes to git (``BranchNameRule``)
    case invalidBase
    /// the new branch isn't a name the app makes (`<number>` or `<number>-<slug>`)
    case invalidBranch

    /// the text under the button
    public var message: String {
        switch self {
        case .unreadable(let problem): "Can't read the checkout: \(problem)"
        case .detached: "The checkout is at a commit without a branch; switch to its base branch first"
        case .notOnBase(let branch): "The checkout is on \(branch), not on its base branch"
        case .dirty(let files): "The checkout has \(files) changed or untracked file\(files == 1 ? "" : "s"); nothing was changed"
        case .invalidBase: "The base branch isn't a valid branch name"
        case .invalidBranch: "That branch name isn't valid"
        }
    }
}

/// How "Start Work Here" ended (WS-08).
public enum StartWorkOutcome: Hashable, Sendable {
    /// the branch exists and is checked out
    case started(branch: String)
    /// a guard stopped it before anything was written
    case refused(StartWorkRefusal)
    /// `git fetch` failed; the checkout is unchanged
    case fetchFailed(status: Int32, lastLine: String)
    /// `git switch` failed; git leaves the checkout as it was
    case switchFailed(status: Int32, lastLine: String)
    /// git couldn't be run, or ran out of time
    case couldNotRun(String)

    /// the text under the button for a failure; `nil` when it worked
    public var problem: String? {
        switch self {
        case .started: nil
        case .refused(let refusal): refusal.message
        case .fetchFailed(_, let line): "git fetch failed: \(line.isEmpty ? "no output" : line). Nothing else was changed"
        case .switchFailed(_, let line): "git switch failed: \(line.isEmpty ? "no output" : line)"
        case .couldNotRun(let problem): problem
        }
    }
}

/// "Start Work Here": on a free checkout, fetch the base branch and start the work item's branch from it (WS-08). The one
/// place where the app writes to a working tree, so every step is guarded:
///
/// - the base and the new branch names are checked first, so neither can be read as an option;
/// - the checkout is read right before the fetch and again right before the switch, and must then be clean and on its
///   base branch (changed and untracked files both count as dirty), so a tree that changed while the fetch ran is never
///   switched;
/// - `git fetch origin <base>`, then `git switch --no-track -c <branch> origin/<base>`: no `--force`, no `reset`, no
///   `stash`, and the new branch doesn't track `origin/<base>` (a later `push` would otherwise go there);
/// - a failed step stops the sequence and nothing else is run.
public struct WorkStarter: Sendable {
    /// how long the fetch may take
    public static let fetchTimeout: Duration = .seconds(120)
    /// how long the switch may take: git's `post-checkout` hook runs inside it
    public static let switchTimeout: Duration = .seconds(120)

    private let runner: any ProcessRunner
    private let reader: GitReader

    public init(runner: any ProcessRunner) {
        self.runner = runner
        reader = GitReader(runner: runner)
    }

    /// Returns the guard's verdict on a reading of the checkout.
    ///
    /// - Parameters:
    ///   - reading: what git last said of the checkout
    ///   - baseBranch: the checkout's base branch
    /// - Returns: why not; `nil` when the checkout is clean and on its base branch
    public static func refusal(_ reading: CheckoutReading, baseBranch: String) -> StartWorkRefusal? {
        switch reading {
        case .failed(let problem):
            return .unreadable(problem)
        case .read(let state):
            guard let branch = state.status.branch else {
                return .detached
            }
            guard branch == baseBranch else {
                return .notOnBase(branch: branch)
            }
            return state.isClean ? nil : .dirty(files: state.changedFiles)
        }
    }

    /// Returns whether the app makes the name: `<number>` or `<number>-<words>` of `a-z0-9`, valid for git.
    ///
    /// - Parameter name: the branch name
    public static func isStartable(branch name: String) -> Bool {
        guard BranchNameRule.isValid(name), let first = name.first, first.isASCII, first.isNumber else {
            return false
        }
        return name.allSatisfy { $0.isASCII && ($0.isNumber || ($0.isLetter && $0.isLowercase) || $0 == "-") }
            && !name.hasSuffix("-") && !name.contains("--")
    }

    /// The fetch's arguments.
    public static func fetchArguments(in path: String, base: String) -> [String] {
        ["-C", path, "fetch", "origin", base]
    }

    /// The switch's arguments.
    public static func switchArguments(in path: String, branch: String, base: String) -> [String] {
        ["-C", path, "switch", "--no-track", "-c", branch, "origin/\(base)"]
    }

    /// Runs the sequence. It never throws: the outcome says what happened.
    ///
    /// - Parameters:
    ///   - checkout: the checkout, which must be free
    ///   - branch: the new branch's name (``BranchSlug/name(number:title:)``)
    ///   - onStep: told after each git call with its name (`fetch`, `switch`) and exit status, for the log
    /// - Returns: the outcome
    public func start(
        in checkout: Checkout, branch: String, onStep: @Sendable (String, Int32) -> Void = { _, _ in }
    ) async -> StartWorkOutcome {
        let base = checkout.baseBranch
        guard BranchNameRule.isValid(base) else {
            return .refused(.invalidBase)
        }
        guard Self.isStartable(branch: branch) else {
            return .refused(.invalidBranch)
        }
        if let refusal = Self.refusal(await reader.read(checkout), baseBranch: base) {
            return .refused(refusal)
        }
        do {
            let fetch = try await runner.run(
                GitReader.git, arguments: Self.fetchArguments(in: checkout.path, base: base), input: nil,
                timeout: Self.fetchTimeout)
            onStep("fetch", fetch.status)
            guard fetch.status == 0 else {
                return .fetchFailed(status: fetch.status, lastLine: GitReader.problem(fetch) ?? "")
            }
            // The fetch can take a while; the tree may have changed meanwhile.
            if let refusal = Self.refusal(await reader.read(checkout), baseBranch: base) {
                return .refused(refusal)
            }
            let switched = try await runner.run(
                GitReader.git, arguments: Self.switchArguments(in: checkout.path, branch: branch, base: base), input: nil,
                timeout: Self.switchTimeout)
            onStep("switch", switched.status)
            guard switched.status == 0 else {
                return .switchFailed(status: switched.status, lastLine: GitReader.problem(switched) ?? "")
            }
            return .started(branch: branch)
        } catch is ProcessTimedOut {
            return .couldNotRun("git took too long; the checkout was not switched")
        } catch {
            return .couldNotRun("Couldn't run git: \(error.localizedDescription)")
        }
    }
}
