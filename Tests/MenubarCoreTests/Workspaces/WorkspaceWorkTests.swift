import Foundation
import Testing

@testable import MenubarCore

/// WS-06 to WS-08: the links back from merge requests and builds, the local branches, and Start Work Here.
@Suite("Workspace work")
struct WorkspaceWorkTests {
    // MARK: - WS-06 Links back and local branches

    private static let gitLab = "https://gitlab.example.com/group/project"

    private func mergeRequest(_ iid: Int, branch: String?) -> MergeRequest {
        MergeRequest(
            iid: iid, title: "MR \(iid)", webURL: URL(string: "\(Self.gitLab)/-/merge_requests/\(iid)")!,
            reference: "group/project!\(iid)", author: MergeRequest.Person(username: "jdoe", name: "Jane Doe"),
            updatedAt: Date(), roles: [.authored], sourceBranch: branch)
    }

    private func checkout(_ name: String) -> Checkout {
        Checkout(path: "/work/\(name)/project", name: name, baseBranch: "develop", folder: UUID())
    }

    private func reading(_ branch: String?) -> CheckoutReading {
        .read(CheckoutState(status: GitStatus(branch: branch)))
    }

    @Test("WS-07 a merge request and its builds lead back to the checkout on their source branch")
    func linksBack() {
        let one = checkout("develop1")
        let two = checkout("develop2")
        let three = checkout("develop3")
        let four = checkout("develop4")
        let five = checkout("develop5")
        let requests = [mergeRequest(87, branch: "1234-fix-login"), mergeRequest(88, branch: "99-detached"),
                        mergeRequest(89, branch: nil)]
        let links = WorkspaceLinks(
            checkouts: [one, two, three, four, five],
            readings: [
                one.id: reading("develop"),  // free: its base branch is no task
                two.id: reading("1234-fix-login"),
                three.id: reading(nil),  // detached
                four.id: .failed("git took longer than 20 s"),
                // five: not read yet
            ],
            mergeRequests: requests)

        #expect(links.entries.map(\.name) == ["develop2"])
        #expect(links.checkout(for: requests[0])?.name == "develop2")
        #expect(links.checkout(for: requests[0])?.id == two.id)
        // A source branch nobody has checked out, or none known (an old cache), has no tag.
        #expect(links.checkout(for: requests[1]) == nil)
        #expect(links.checkout(for: requests[2]) == nil)
        // The base branch never leads anywhere, even for a merge request from it.
        #expect(links.checkout(onBranch: "develop") == nil)

        func build(_ job: String, url: String? = nil) -> Build {
            Build(job: job, number: 3, gitLabURL: url.flatMap(URL.init(string:)), kind: .mine, phase: .running, startedAt: Date())
        }
        // MR-87 is merge request !87's build; a branch build is named by its branch, encoded twice by Jenkins.
        #expect(links.checkout(for: build("MR-87"))?.name == "develop2")
        #expect(links.checkout(for: build("MR-87", url: "\(Self.gitLab)/-/merge_requests/87"))?.name == "develop2")
        // The same number in another project is another merge request.
        #expect(links.checkout(for: build("MR-87", url: "https://gitlab.example.com/group/other/-/merge_requests/87")) == nil)
        #expect(links.checkout(for: build("MR-500")) == nil)
        #expect(links.checkout(for: build("1234-fix-login"))?.name == "develop2")
        #expect(links.checkout(for: build("feature%252Fcool")) == nil)
        let slashed = WorkspaceLinks(
            checkouts: [one], readings: [one.id: reading("feature/cool")], mergeRequests: [])
        #expect(slashed.checkout(for: build("feature%252Fcool"))?.name == "develop1")
    }

    @Test("WS-06 parses the local branches with their tracking, their distance to the base and their last commit")
    func parsesBranches() throws {
        let s = "\u{1F}"
        let output = [
            "*\(s)1234-fix\(s)origin/1234-fix\(s)ahead 2, behind 1\(s)1761700000\(s)3 4\(s)Fix the login: tab\tand more",
            " \(s)55-new\(s)\(s)\(s)1761600000\(s)1 0\(s)Start",
            " \(s)77-merged\(s)origin/77-merged\(s)gone\(s)1761500000\(s)0 9\(s)Old",
            " \(s)88-synced\(s)origin/88-synced\(s)\(s)1761400000\(s)\(s)In sync, no base distance",
            "garbage without fields",
            " \(s)\(s)\(s)\(s)0\(s)\(s)no name",
        ].joined(separator: "\n")
        let branches = LocalBranch.parse(output)

        #expect(branches.map(\.name) == ["1234-fix", "55-new", "77-merged", "88-synced"])
        let first = try #require(branches.first)
        #expect(first.isCurrent)
        #expect(first.upstream == "origin/1234-fix")
        #expect(first.aheadOfUpstream == 2 && first.behindUpstream == 1)
        #expect(first.aheadOfBase == 3 && first.behindBase == 4)
        #expect(first.subject == "Fix the login: tab\tand more")
        #expect(first.committedAt == Date(timeIntervalSince1970: 1_761_700_000))
        #expect(first.isPushed)
        // No upstream: not known to be pushed (GitReader checks origin by name), no distance to a remote.
        #expect(branches[1].upstream == nil && !branches[1].isPushed && branches[1].aheadOfUpstream == nil)
        // A gone upstream isn't pushed any more.
        #expect(branches[2].upstreamGone && !branches[2].isPushed && branches[2].aheadOfUpstream == nil)
        // In sync: zeros; a git without ahead-behind: no distance to the base.
        #expect(branches[3].aheadOfUpstream == 0 && branches[3].behindUpstream == 0)
        #expect(branches[3].aheadOfBase == nil)
    }

    @Test("WS-06 lists the branches that have no merge request, not the base")
    func branchesWithoutMergeRequest() {
        let branches = ["develop", "1234-fix", "55-new", "77-other"].map { LocalBranch(name: $0) }
        let requests = [mergeRequest(1, branch: "1234-fix"), mergeRequest(2, branch: nil)]
        #expect(LocalBranch.withoutMergeRequest(branches, base: "develop", mergeRequests: requests).map(\.name) == ["55-new", "77-other"])
        #expect(LocalBranch.withoutMergeRequest(branches, base: "develop", mergeRequests: []).count == 3)
    }

    @Test("WS-06 the new merge request link carries the source and target branch")
    func newMergeRequestLink() throws {
        let gitLab = try #require(URL(string: "https://gitlab.example.com/"))
        let url = NewMergeRequestLink.url(gitLab: gitLab, project: "group/sub/project", source: "feature/12-fix&more", target: "develop")
        #expect(url?.absoluteString == "https://gitlab.example.com/group/sub/project/-/merge_requests/new"
            + "?merge_request%5Bsource_branch%5D=feature/12-fix%26more&merge_request%5Btarget_branch%5D=develop")
        #expect(NewMergeRequestLink.url(gitLab: gitLab, project: "", source: "a", target: "develop") == nil)
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        #expect(components?.queryItems?.first?.name == "merge_request[source_branch]")
        #expect(components?.queryItems?.first?.value == "feature/12-fix&more")
    }

    @Test("WS-06 reads the local branches of a real repository, read-only")
    func readsRealBranches() async throws {
        let rig = try await Rig()
        try await rig.git("switch", "-q", "-c", "12-pushed")
        try await rig.commit("pushed one")
        try await rig.git("push", "-q", "-u", "origin", "12-pushed")
        try await rig.commit("pushed two, local only")
        try await rig.git("switch", "-q", "-c", "13-tracked-by-name", "develop")
        try await rig.commit("untracked but on origin")
        try await rig.git("push", "-q", "origin", "13-tracked-by-name")
        try await rig.git("switch", "-q", "-c", "14-local", "develop")
        try await rig.commit("local only")
        let index = rig.work.appending(path: ".git/index")
        let before = try Data(contentsOf: index)

        let reading = await GitReader(runner: SystemProcessRunner()).readBranches(rig.checkout)

        guard case .read(let result) = reading else {
            Issue.record("Not read: \(reading)")
            return
        }
        #expect(result.total == 4)
        let byName = Dictionary(uniqueKeysWithValues: result.branches.map { ($0.name, $0) })
        let pushed = try #require(byName["12-pushed"])
        #expect(pushed.isPushed && pushed.aheadOfUpstream == 1 && pushed.behindUpstream == 0)
        #expect(pushed.aheadOfBase == 2 && pushed.behindBase == 0)
        #expect(pushed.subject == "pushed two, local only")
        #expect(byName["13-tracked-by-name"]?.isPushed == true)
        #expect(byName["13-tracked-by-name"]?.upstream == nil)
        #expect(byName["14-local"]?.isPushed == false)
        #expect(byName["14-local"]?.isCurrent == true)
        #expect(try Data(contentsOf: index) == before)
    }

    // MARK: - WS-08 Branch names

    @Test(
        "WS-08 names the branch like GitLab: the number, then the title as a slug",
        arguments: [
            (1234, "Fix the login timeout", "1234-fix-the-login-timeout"),
            (7, "Übergrößen: Café, naïve façade & Ångström", "7-ubergrossen-cafe-naive-facade-angstrom"),
            (12, "Æsir, Øresund and Łódź", "12-aesir-oresund-and-lodz"),
            (5, "  [cascade] \"Quoted\" (parens)/slash\\back...  ", "5-cascade-quoted-parens-slash-back"),
            (9, "Fix #42 -- again_and_again", "9-fix-42-again-and-again"),
            (3, "UPPER lower MiXeD", "3-upper-lower-mixed"),
            (8, "日本語 only", "8-only"),
            (4, "!!! ???", "4"),
            (6, "", "6"),
            (21, "Rework 3.0: the 2nd pass", "21-rework-3-0-the-2nd-pass"),
        ] as [(Int, String, String)])
    func branchSlug(number: Int, title: String, expected: String) {
        #expect(BranchSlug.name(number: number, title: title) == expected)
        // Whatever the title, the app only makes names it starts work with.
        #expect(WorkStarter.isStartable(branch: BranchSlug.name(number: number, title: title) ?? ""))
    }

    @Test("WS-08 cuts a long title at 100 characters without ending in a dash")
    func branchSlugLength() throws {
        let title = String(repeating: "word ", count: 60)
        let name = try #require(BranchSlug.name(number: 1234, title: title))
        #expect(name.count <= BranchSlug.maximumLength)
        #expect(!name.hasSuffix("-"))
        #expect(name.hasPrefix("1234-word-word"))
        // A cut right after a dash drops the dash.
        let exact = "x".repeated(94)
        let cut = try #require(BranchSlug.name(number: 1234, title: "\(exact) tail"))
        #expect(cut == "1234-\(exact)")
        #expect(BranchSlug.name(number: 0, title: "x") == nil)
        #expect(BranchSlug.name(number: -3, title: "x") == nil)
    }

    @Test(
        "WS-08 starts work only on branch names it made itself",
        arguments: [
            ("1234-fix", true), ("1234", true), ("-1234", false), ("--force", false), ("1234-", false),
            ("12--34", false), ("feature/12", false), ("12 fix", false), ("12-Fix", false), ("", false), ("develop", false),
            ("12..3", false),
        ] as [(String, Bool)])
    func startableNames(name: String, startable: Bool) {
        #expect(WorkStarter.isStartable(branch: name) == startable)
    }

    // MARK: - WS-08 Start Work Here

    @Test(
        "WS-08 guards: only a clean checkout on its base branch may start",
        arguments: [
            (CheckoutReading.read(CheckoutState(status: GitStatus(branch: "develop"))), nil),
            (.read(CheckoutState(status: GitStatus(branch: "develop"), ahead: 3, behind: 40)), nil),
            (.read(CheckoutState(status: GitStatus(branch: "develop", changedFiles: 2))), .dirty(files: 2)),
            (.read(CheckoutState(status: GitStatus(branch: "develop", untrackedFiles: 1))), .dirty(files: 1)),
            (.read(CheckoutState(status: GitStatus(branch: "1234-fix"))), .notOnBase(branch: "1234-fix")),
            (.read(CheckoutState(status: GitStatus(branch: nil))), .detached),
            (.failed("not a git repository"), .unreadable("not a git repository")),
        ] as [(CheckoutReading, StartWorkRefusal?)])
    func guards(reading: CheckoutReading, refusal: StartWorkRefusal?) {
        #expect(WorkStarter.refusal(reading, baseBranch: "develop") == refusal)
    }

    @Test("WS-08 fetches the base, then switches to the new branch from origin without tracking it, nothing forced")
    func startsWork() async throws {
        let rig = try await Rig()
        // origin/develop moves on after the clone: the fetch is what brings the new branch to it.
        try await rig.otherClone.commit("moved on")
        let runner = RecordingRunner()

        let outcome = await WorkStarter(runner: runner).start(in: rig.checkout, branch: "1234-fix-login")

        #expect(outcome == .started(branch: "1234-fix-login"))
        #expect(try await rig.output("branch", "--show-current") == "1234-fix-login")
        #expect(try await rig.output("rev-parse", "HEAD") == (try await rig.otherClone.output("rev-parse", "HEAD")))
        // No upstream: a `git push` never goes to origin/develop by mistake.
        #expect(try await rig.output("config", "--get", "branch.1234-fix-login.remote", allowFailure: true) == "")
        let writes = await runner.writes
        #expect(writes == [
            ["fetch", "origin", "develop"],
            ["switch", "--no-track", "-c", "1234-fix-login", "origin/develop"],
        ])
        let all = await runner.calls.flatMap { $0 }
        for forbidden in ["--force", "-f", "reset", "stash", "clean", "checkout", "pull", "merge", "rebase"] {
            #expect(!all.contains(forbidden), "\(forbidden)")
        }
    }

    @Test("WS-08 never starts on a dirty tree, on another branch or on a detached HEAD, and then runs no write")
    func refusesToStart() async throws {
        let rig = try await Rig()
        let runner = RecordingRunner()
        let starter = WorkStarter(runner: runner)

        try "edited\n".write(to: rig.work.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        #expect(await starter.start(in: rig.checkout, branch: "1-x") == .refused(.dirty(files: 1)))
        try await rig.git("checkout", "-q", "--", "a.txt")
        try "new\n".write(to: rig.work.appending(path: "untracked.txt"), atomically: true, encoding: .utf8)
        #expect(await starter.start(in: rig.checkout, branch: "1-x") == .refused(.dirty(files: 1)))
        try FileManager.default.removeItem(at: rig.work.appending(path: "untracked.txt"))

        try await rig.git("switch", "-q", "-c", "other")
        #expect(await starter.start(in: rig.checkout, branch: "1-x") == .refused(.notOnBase(branch: "other")))
        try await rig.git("switch", "-q", "--detach", "develop")
        #expect(await starter.start(in: rig.checkout, branch: "1-x") == .refused(.detached))

        // Names git could read as an option, or that the app doesn't make, never reach git.
        try await rig.git("switch", "-q", "develop")
        #expect(await starter.start(in: rig.checkout, branch: "--force") == .refused(.invalidBranch))
        let badBase = Checkout(path: rig.checkout.path, name: "develop3", baseBranch: "--output=x", folder: UUID())
        #expect(await starter.start(in: badBase, branch: "1-x") == .refused(.invalidBase))

        #expect(await runner.writes.isEmpty)
        #expect(try await rig.output("branch", "--show-current") == "develop")
    }

    @Test("WS-08 a failed fetch stops the sequence and changes nothing, with git's last line")
    func fetchFails() async throws {
        let rig = try await Rig()
        try await rig.git("remote", "set-url", "origin", rig.folder.url.appending(path: "gone.git").path(percentEncoded: false))
        let runner = RecordingRunner()

        let outcome = await WorkStarter(runner: runner).start(in: rig.checkout, branch: "1234-fix")

        guard case .fetchFailed(let status, let line) = outcome else {
            Issue.record("Expected a failed fetch, got \(outcome)")
            return
        }
        #expect(status != 0)
        #expect(!line.isEmpty)
        #expect(outcome.problem?.hasPrefix("git fetch failed: ") == true)
        #expect(await runner.writes == [["fetch", "origin", "develop"]])
        #expect(try await rig.output("branch", "--show-current") == "develop")
    }

    @Test("WS-08 a tree that changed while the fetch ran is never switched")
    func treeChangesDuringFetch() async throws {
        let rig = try await Rig()
        let path = rig.work.appending(path: "a.txt")
        let runner = RecordingRunner(afterFetch: { try? "edited meanwhile\n".write(to: path, atomically: true, encoding: .utf8) })

        let outcome = await WorkStarter(runner: runner).start(in: rig.checkout, branch: "1234-fix")

        #expect(outcome == .refused(.dirty(files: 1)))
        #expect(await runner.writes == [["fetch", "origin", "develop"]])
        #expect(try await rig.output("branch", "--show-current") == "develop")
        #expect(try String(contentsOf: path, encoding: .utf8) == "edited meanwhile\n")
    }

    @Test("WS-08 a branch that exists already fails in git's words, without moving the checkout")
    func branchExists() async throws {
        let rig = try await Rig()
        try await rig.git("branch", "1234-fix")

        let outcome = await WorkStarter(runner: SystemProcessRunner()).start(in: rig.checkout, branch: "1234-fix")

        guard case .switchFailed(_, let line) = outcome else {
            Issue.record("Expected a failed switch, got \(outcome)")
            return
        }
        #expect(line.contains("already exists"))
        #expect(try await rig.output("branch", "--show-current") == "develop")
    }

    @Test("WS-08 the store shows git's last line and logs only the checkout's name, the branch and the exit codes")
    @MainActor
    func storeStartsWork() async throws {
        let rig = try await Rig()
        let defaults = TemporaryDefaults()
        let logFolder = try TemporaryFolder()
        let log = ActivityLog(folder: logFolder.url, now: { Date() })
        let store = WorkspacesStore(
            defaults: defaults.defaults, runner: SystemProcessRunner(), log: log, home: logFolder.url)

        let outcome = await store.startWork(in: rig.checkout, branch: "1234-fix-login")
        #expect(outcome == .started(branch: "1234-fix-login"))
        #expect(store.actionNotes[rig.checkout.id]?.hasPrefix("Started 1234-fix-login") == true)
        #expect(store.actionProblems[rig.checkout.id] == nil)
        // Now on the task's branch, so a second start is refused, with the reason on screen.
        let again = await store.startWork(in: rig.checkout, branch: "1235-other")
        #expect(again == .refused(.notOnBase(branch: "1234-fix-login")))
        #expect(store.actionProblems[rig.checkout.id] != nil)
        #expect(store.startingWork.isEmpty)

        try await Task.sleep(for: .milliseconds(300))
        let text = await log.entries().map(\.message).joined(separator: "\n")
        #expect(text.contains("Start Work Here: develop3, branch 1234-fix-login, exit codes fetch 0, switch 0"))
        #expect(text.contains("Start Work Here refused in develop3"))
        #expect(!text.contains(rig.folder.url.lastPathComponent))
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}

/// A bare "origin", a clone of it as the checkout `develop3`, and a second clone that pushes to it.
private struct Rig {
    let folder: TemporaryFolder
    let work: URL
    let checkout: Checkout
    let otherClone: Clone

    /// A clone of the same origin, to move origin on.
    struct Clone {
        let url: URL

        func git(_ arguments: String...) async throws {
            _ = try await Rig.run(url, arguments, allowFailure: false)
        }

        func output(_ arguments: String...) async throws -> String {
            try await Rig.run(url, arguments, allowFailure: false)
        }

        /// Commits a new file and pushes it to origin's develop.
        func commit(_ message: String) async throws {
            try message.write(to: url.appending(path: "\(UUID().uuidString).txt"), atomically: true, encoding: .utf8)
            try await git("add", "-A")
            try await git("commit", "-q", "-m", message)
            try await git("push", "-q", "origin", "develop")
        }
    }

    init() async throws {
        folder = try TemporaryFolder()
        let base = folder.url.resolvingSymlinksInPath()
        let origin = base.appending(path: "origin.git", directoryHint: .isDirectory)
        work = base.appending(path: "develop3", directoryHint: .isDirectory)
        let other = base.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        _ = try await Self.run(base, ["init", "-q", "--bare", "-b", "develop", origin.path(percentEncoded: false)], allowFailure: false)
        // The first clone seeds origin's develop.
        _ = try await Self.run(base, ["clone", "-q", origin.path(percentEncoded: false), other.path(percentEncoded: false)], allowFailure: false)
        try "one\n".write(to: other.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        otherClone = Clone(url: other)
        _ = try await Self.run(other, ["switch", "-q", "-c", "develop"], allowFailure: true)
        try await otherClone.git("add", "-A")
        try await otherClone.git("commit", "-q", "-m", "one")
        try await otherClone.git("push", "-q", "origin", "develop")
        _ = try await Self.run(base, ["clone", "-q", origin.path(percentEncoded: false), work.path(percentEncoded: false)], allowFailure: false)
        checkout = Checkout(path: work.path(percentEncoded: false), name: "develop3", baseBranch: "develop", folder: UUID())
    }

    func git(_ arguments: String...) async throws {
        _ = try await Self.run(work, arguments, allowFailure: false)
    }

    func output(_ arguments: String..., allowFailure: Bool = false) async throws -> String {
        try await Self.run(work, arguments, allowFailure: allowFailure)
    }

    /// Commits a new file in the checkout.
    func commit(_ message: String) async throws {
        try message.write(to: work.appending(path: "\(UUID().uuidString).txt"), atomically: true, encoding: .utf8)
        try await git("add", "-A")
        try await git("commit", "-q", "-m", message)
    }

    /// Runs git in a folder with no hooks, no signing and a fixed author; returns stdout, trimmed.
    static func run(_ directory: URL, _ arguments: [String], allowFailure: Bool) async throws -> String {
        let output = try await SystemProcessRunner().run(
            GitReader.git,
            arguments: ["-C", directory.path(percentEncoded: false), "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                        "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "init.defaultBranch=develop"] + arguments,
            input: nil, timeout: .seconds(30))
        if !allowFailure, output.status != 0 {
            Issue.record("git \(arguments.joined(separator: " ")) failed: \(String(decoding: output.standardError, as: UTF8.self))")
        }
        return String(decoding: output.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs the real git and records every call without the leading `-C <path>`; `writes` are the calls that can change a
/// checkout. `afterFetch` runs once a fetch ended, to change the tree behind the app's back.
private actor RecordingRunner: ProcessRunner {
    private(set) var calls: [[String]] = []
    private let afterFetch: (@Sendable () -> Void)?
    private let real = SystemProcessRunner()

    init(afterFetch: (@Sendable () -> Void)? = nil) {
        self.afterFetch = afterFetch
    }

    /// the calls that aren't reads: the app's reads all carry `--no-optional-locks`
    var writes: [[String]] {
        calls.filter { !$0.contains("--no-optional-locks") }
    }

    func run(_ executable: URL, arguments: [String], input: Data?) async throws -> ProcessOutput {
        // Without the "-C <path>" every call starts with.
        let command = Array(arguments.dropFirst(2))
        calls.append(command)
        let output = try await real.run(executable, arguments: arguments, input: input)
        if command.first == "fetch" {
            afterFetch?()
        }
        return output
    }
}
