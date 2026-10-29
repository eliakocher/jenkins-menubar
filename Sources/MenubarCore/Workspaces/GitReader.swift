import Foundation

/// What `git status --porcelain=v2 --branch` says of a checkout: its branch and how many files differ (WS-02).
public struct GitStatus: Hashable, Sendable {
    /// the checked out branch; `nil` for a detached HEAD
    public var branch: String?
    /// the tracked files with changes, staged or not, conflicts included
    public var changedFiles: Int
    /// the files git doesn't track and doesn't ignore; an untracked folder counts once
    public var untrackedFiles: Int

    public init(branch: String?, changedFiles: Int = 0, untrackedFiles: Int = 0) {
        self.branch = branch
        self.changedFiles = changedFiles
        self.untrackedFiles = untrackedFiles
    }

    /// Reads the porcelain v2 output. Only the line kinds are counted; no file name is kept.
    ///
    /// - Parameter output: the output of `status --porcelain=v2 --branch`
    /// - Returns: the status
    public static func parse(porcelainV2 output: String) -> GitStatus {
        var status = GitStatus(branch: nil)
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                status.branch = head == "(detached)" ? nil : head
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                status.changedFiles += 1
            } else if line.hasPrefix("? ") {
                status.untrackedFiles += 1
            }
        }
        return status
    }
}

/// What the app knows of a checkout after reading it with git (WS-02, WS-03).
public struct CheckoutState: Hashable, Sendable {
    /// the branch and the changed files
    public var status: GitStatus
    /// the commits on HEAD that `origin/<base>` doesn't have; `nil` when `origin/<base>` is unknown
    public var ahead: Int?
    /// the commits on `origin/<base>` that HEAD doesn't have; `nil` when `origin/<base>` is unknown
    public var behind: Int?
    /// the commits on `origin/<base>` that the local base branch doesn't have; `nil` without a local base branch
    public var localBaseBehind: Int?

    public init(status: GitStatus, ahead: Int? = nil, behind: Int? = nil, localBaseBehind: Int? = nil) {
        self.status = status
        self.ahead = ahead
        self.behind = behind
        self.localBaseBehind = localBaseBehind
    }

    /// the commits the local base branch may lag behind `origin/<base>` before the row warns quietly (the plan saw a
    /// `develop` 674 commits behind)
    public static let staleBaseThreshold = 100

    /// whether no file differs from HEAD, untracked ones included
    public var isClean: Bool {
        status.changedFiles == 0 && status.untrackedFiles == 0
    }

    /// the changed and untracked files together, as "N changed files" counts them
    public var changedFiles: Int {
        status.changedFiles + status.untrackedFiles
    }

    /// Returns whether the checkout is free for the next task: clean, on its base branch (WS-03). Ahead or behind
    /// doesn't matter: the next task starts from `origin/<base>`.
    ///
    /// - Parameter baseBranch: the checkout's base branch
    /// - Returns: `true` when free
    public func isFree(baseBranch: String) -> Bool {
        isClean && status.branch == baseBranch
    }

    /// whether the local base branch lags far behind `origin/<base>`, which turns a diff against it into thousands of
    /// files
    public var hasStaleBase: Bool {
        (localBaseBehind ?? 0) >= Self.staleBaseThreshold
    }
}

/// A checkout's state as last read: the state, or why git couldn't read it.
public enum CheckoutReading: Hashable, Sendable {
    case read(CheckoutState)
    /// the problem, like "git took longer than 20 s"
    case failed(String)

    /// the state, when it was read
    public var state: CheckoutState? {
        if case .read(let state) = self { state } else { nil }
    }
}

/// Reads checkouts with `git`, read-only, through a ``ProcessRunner`` (WS-02).
///
/// Every call runs `git -C <checkout> --no-optional-locks -c core.fsmonitor=false`: the app never takes git's index lock
/// while the user works, nor starts git's file system monitor daemon; nothing writes, not even to `.git`. It never
/// fetches: `origin/<base>` is as of the user's last fetch. Each call has a time limit, and runs off the main actor.
public struct GitReader: Sendable {
    /// the git of the Command Line Tools, which every developer Mac has
    public static let git = URL(filePath: "/usr/bin/git")
    /// the time limit of each call; the plan measured 0.07 to 0.32 s on a checkout of 35,635 files
    public static let timeout: Duration = .seconds(20)

    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner) {
        self.runner = runner
    }

    /// Returns the arguments of a git call in a checkout, with the options that keep it read-only.
    ///
    /// - Parameters:
    ///   - path: the checkout's folder, absolute
    ///   - command: the git command and its arguments
    /// - Returns: the arguments for `/usr/bin/git`
    public static func arguments(in path: String, _ command: [String]) -> [String] {
        ["-C", path, "--no-optional-locks", "-c", "core.fsmonitor=false"] + command
    }

    /// The three commands that read a checkout, after ``arguments(in:_:)``. The branch name is checked first
    /// (``BranchNameRule``), and `--end-of-options` keeps git from reading a revision as an option.
    public enum Command {
        /// the branch and the changed files, untracked folders counted once
        public static let status = ["status", "--porcelain=v2", "--branch", "--no-ahead-behind", "--untracked-files=normal"]

        /// what `origin/<base>` has that HEAD doesn't, and the other way round: "behind<TAB>ahead"
        public static func aheadBehind(base: String) -> [String] {
            ["rev-list", "--left-right", "--count", "--end-of-options", "origin/\(base)...HEAD"]
        }

        /// what `origin/<base>` has that the local base branch doesn't
        public static func localBaseBehind(base: String) -> [String] {
            ["rev-list", "--count", "--end-of-options", "\(base)..origin/\(base)"]
        }

        /// the local branches, the most recently committed first, with their tracking state, their distance to
        /// `origin/<base>` and their last commit (WS-06); `for-each-ref` only reads
        public static func localBranches(base: String, withBaseDistance: Bool = true) -> [String] {
            let fields = ["%(HEAD)", "%(refname:lstrip=2)", "%(upstream:short)", "%(upstream:track,nobracket)",
                          "%(committerdate:unix)", withBaseDistance ? "%(ahead-behind:origin/\(base))" : "", "%(contents:subject)"]
            return ["for-each-ref", "--sort=-committerdate", "--format=" + fields.joined(separator: "%1f"), "refs/heads"]
        }

        /// which of the named branches `origin` has, by name; only the exact names are listed
        public static func remoteBranches(named names: [String]) -> [String] {
            ["for-each-ref", "--format=%(refname:lstrip=3)"] + names.map { "refs/remotes/origin/\($0)" }
        }
    }

    /// Reads a checkout: its status, then ahead and behind `origin/<base>`, then how far the local base lags. A
    /// missing `origin/<base>` or local base leaves those unknown; only a failed status fails the reading.
    ///
    /// - Parameter checkout: the checkout
    /// - Returns: the state, or why git couldn't read it
    public func read(_ checkout: Checkout) async -> CheckoutReading {
        guard BranchNameRule.isValid(checkout.baseBranch) else {
            return .failed(FolderFindings.Problem.invalidBaseBranch.message)
        }
        let status: GitStatus
        do {
            let output = try await git(checkout, Command.status)
            guard output.status == 0 else {
                return .failed(Self.problem(output) ?? "git status failed (exit \(output.status))")
            }
            status = GitStatus.parse(porcelainV2: String(decoding: output.standardOutput, as: UTF8.self))
        } catch is ProcessTimedOut {
            return .failed("git took longer than \(Int(Self.timeout.components.seconds)) s")
        } catch {
            return .failed("Couldn't run git: \(error.localizedDescription)")
        }
        var state = CheckoutState(status: status)
        if let counts = await count(checkout, Command.aheadBehind(base: checkout.baseBranch)), counts.count == 2 {
            state.behind = counts[0]
            state.ahead = counts[1]
        }
        state.localBaseBehind = await count(checkout, Command.localBaseBehind(base: checkout.baseBranch))?.first
        return .read(state)
    }

    /// Reads a checkout's local branches: `for-each-ref` of `refs/heads`, then which of the first
    /// ``LocalBranches/maximum`` have a branch of the same name on `origin` without tracking it. An older git that
    /// doesn't know `ahead-behind` still lists them, without the distance to the base. Read-only, like ``read(_:)``.
    ///
    /// - Parameters:
    ///   - checkout: the checkout
    ///   - now: the current time, for ``LocalBranches/readAt``
    /// - Returns: the branches, or why git couldn't list them
    public func readBranches(_ checkout: Checkout, now: Date = Date()) async -> LocalBranchesReading {
        guard BranchNameRule.isValid(checkout.baseBranch) else {
            return .failed(FolderFindings.Problem.invalidBaseBranch.message)
        }
        do {
            var output = try await git(checkout, Command.localBranches(base: checkout.baseBranch))
            if output.status != 0 {
                output = try await git(checkout, Command.localBranches(base: checkout.baseBranch, withBaseDistance: false))
            }
            guard output.status == 0 else {
                return .failed(Self.problem(output) ?? "git for-each-ref failed (exit \(output.status))")
            }
            let all = LocalBranch.parse(String(decoding: output.standardOutput, as: UTF8.self))
            var branches = Array(all.prefix(LocalBranches.maximum))
            let untracked = branches.filter { !$0.isPushed }.map(\.name).filter(BranchNameRule.isValid)
            if !untracked.isEmpty,
               let remote = try? await git(checkout, Command.remoteBranches(named: untracked)), remote.status == 0 {
                let pushed = Set(String(decoding: remote.standardOutput, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init))
                for index in branches.indices where pushed.contains(branches[index].name) {
                    branches[index].isPushed = true
                }
            }
            return .read(LocalBranches(branches: branches, total: all.count, readAt: now))
        } catch is ProcessTimedOut {
            return .failed("git took longer than \(Int(Self.timeout.components.seconds)) s")
        } catch {
            return .failed("Couldn't run git: \(error.localizedDescription)")
        }
    }

    /// Reads the counts of `rev-list --count`, one or two numbers.
    ///
    /// - Parameter output: the output, like `14\t2\n`
    /// - Returns: the numbers; `nil` when the output isn't only numbers
    public static func counts(_ output: String) -> [Int]? {
        let fields = output.split(whereSeparator: { $0 == "\t" || $0 == " " || $0.isNewline })
        let numbers = fields.compactMap { Int($0) }
        return numbers.isEmpty || numbers.count != fields.count ? nil : numbers
    }

    /// Runs a counting command; an unknown revision, a failure or a timeout is `nil`.
    private func count(_ checkout: Checkout, _ command: [String]) async -> [Int]? {
        guard let output = try? await git(checkout, command), output.status == 0 else {
            return nil
        }
        return Self.counts(String(decoding: output.standardOutput, as: UTF8.self))
    }

    private func git(_ checkout: Checkout, _ command: [String]) async throws -> ProcessOutput {
        try await runner.run(
            Self.git, arguments: Self.arguments(in: checkout.path, command), input: nil, timeout: Self.timeout)
    }

    /// The last line git wrote to stderr, like "fatal: not a git repository", without the file names of other lines.
    static func problem(_ output: ProcessOutput) -> String? {
        String(decoding: output.standardError, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .last
            .map { String($0.prefix(200)) }
    }
}
