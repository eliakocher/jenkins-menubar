import Foundation
import Testing

@testable import MenubarCore

@Suite("Workspaces")
struct WorkspacesTests {
    // MARK: - WS-01 Settings → Repositories and discovery

    @Test("WS-01 finds the checkouts of a pattern, one folder level per star")
    func findsPatternCheckouts() throws {
        let folder = try TemporaryFolder()
        for name in ["develop1", "develop2", "develop10"] {
            try folder.write("", to: "workspaces/\(name)/project/.git/HEAD")
        }
        // A worktree's .git is a file; a clone without the subfolder, a hidden folder and a plain folder don't count.
        try folder.write("gitdir: /elsewhere", to: "workspaces/develop3/project/.git")
        try folder.write("", to: "workspaces/other/README")
        try folder.write("", to: "workspaces/.hidden/project/.git/HEAD")
        try folder.write("", to: "workspaces/plain/project/README")
        let base = (folder.url.resolvingSymlinksInPath().path(percentEncoded: false) as NSString).standardizingPath
        let entry = RepositoryFolder(path: "\(base)/workspaces/*/project")

        let found = WorkspaceDiscovery.find(entry, home: folder.url)
        #expect(found.problem == nil)
        #expect(found.checkouts.map(\.name) == ["develop1", "develop2", "develop3", "develop10"])
        #expect(found.checkouts.first?.path == "\(base)/workspaces/develop1/project")
        #expect(found.checkouts.allSatisfy { $0.baseBranch == "develop" })

        // The same checkout through a second entry counts once.
        let single = RepositoryFolder(path: "\(base)/workspaces/develop2/project", baseBranch: "main")
        let both = WorkspaceDiscovery.find([entry, single], home: folder.url)
        #expect(both[1].checkouts.isEmpty)

        // The home folder as ~, and what each kind of entry says when it finds nothing.
        let home = URL(filePath: base, directoryHint: .isDirectory)
        #expect(WorkspaceDiscovery.find(RepositoryFolder(path: "~/workspaces/*/project"), home: home).checkouts.count == 4)
        #expect(WorkspaceDiscovery.find(RepositoryFolder(path: "~/workspaces/*/nothing"), home: home).problem == .noMatches)
        #expect(WorkspaceDiscovery.find(RepositoryFolder(path: "~/workspaces/plain/project"), home: home).problem == .notACheckout)
        #expect(WorkspaceDiscovery.find(RepositoryFolder(path: "~/gone"), home: home).problem == .missing)
        #expect(WorkspaceDiscovery.find(RepositoryFolder(path: "workspaces/*"), home: home).problem == .notAbsolute)
        #expect(WorkspaceDiscovery.find(RepositoryFolder(path: "~/workspaces/*/project", baseBranch: "--output=x"), home: home)
            .problem == .invalidBaseBranch)
    }

    @Test("WS-01 Add Folder suggests the pattern of clones side by side")
    func suggestsPattern() throws {
        let folder = try TemporaryFolder()
        try folder.write("", to: "clones/develop1/project/.git/HEAD")
        try folder.write("", to: "clones/develop2/project/.git/HEAD")
        try folder.write("", to: "clones/develop2/tools/.git/HEAD")
        try folder.write("", to: "flat/a/.git/HEAD")
        try folder.write("", to: "single/.git/HEAD")
        try folder.write("", to: "empty/README")
        let base = (folder.url.resolvingSymlinksInPath().path(percentEncoded: false) as NSString).standardizingPath
        let home = URL(filePath: base, directoryHint: .isDirectory)

        #expect(WorkspaceDiscovery.suggestedPath(for: "\(base)/clones", home: home) == "~/clones/*/project")
        #expect(WorkspaceDiscovery.suggestedPath(for: "\(base)/flat", home: home) == "~/flat/*")
        #expect(WorkspaceDiscovery.suggestedPath(for: "\(base)/single", home: home) == "~/single")
        #expect(WorkspaceDiscovery.suggestedPath(for: "\(base)/empty", home: home) == "~/empty")
    }

    @Test(
        "WS-01 refuses base branches git could read as an option or a range",
        arguments: [
            ("develop", true), ("main", true), ("release/2026.1", true), ("", false), ("-x", false), ("--output=f", false),
            ("a..b", false), ("a b", false), ("a~1", false), ("a^", false), ("a:b", false), ("HEAD@{1}", false),
            ("/develop", false), ("develop/", false),
        ])
    func refusesBadBaseBranches(name: String, valid: Bool) {
        #expect(BranchNameRule.isValid(name) == valid)
    }

    @Test("WS-01 keeps the repositories in the user's preferences")
    @MainActor
    func keepsSettings() async throws {
        let defaults = TemporaryDefaults()
        // A home of its own: the store looks for the checkouts, never in the user's folders.
        let home = try TemporaryFolder()
        let store = WorkspacesStore(defaults: defaults.defaults, runner: FakeGit(), home: home.url)
        let settings = RepositorySettings(
            folders: [RepositoryFolder(path: "~/workspaces/*/project", baseBranch: "main")], ideCommand: "code {path}")
        store.update(settings)
        #expect(RepositorySettings.load(from: defaults.defaults) == settings)
        #expect(WorkspacesStore(defaults: defaults.defaults, runner: FakeGit(), home: home.url).settings == settings)
        await store.settled()
        #expect(store.findings.first?.problem == .noMatches)
    }

    // MARK: - WS-02 Reading a checkout with git

    @Test(
        "WS-02 parses git status",
        arguments: [
            ("# branch.oid abc\n# branch.head develop\n", GitStatus(branch: "develop")),
            ("# branch.oid (initial)\n# branch.head (detached)\n", GitStatus(branch: nil)),
            (
                "# branch.head 12-fix\n# branch.upstream origin/12-fix\n1 .M N... 100644 100644 100644 a b f.txt\n"
                    + "2 R. N... 100644 100644 100644 a b R100 new.txt\told.txt\nu UU N... 1 2 3 4 a b c x.txt\n"
                    + "? new folder/\n? notes.txt\n",
                GitStatus(branch: "12-fix", changedFiles: 3, untrackedFiles: 2)
            ),
        ])
    func parsesStatus(output: String, status: GitStatus) {
        #expect(GitStatus.parse(porcelainV2: output) == status)
    }

    @Test(
        "WS-02 parses rev-list counts",
        arguments: [("14\t2\n", [14, 2]), ("674\n", [674]), ("0\t0", [0, 0]), ("", nil), ("fatal: bad\n", nil)] as [(String, [Int]?)])
    func parsesCounts(output: String, counts: [Int]?) {
        #expect(GitReader.counts(output) == counts)
    }

    @Test("WS-02 every git call is read-only, never fetches, and keeps branch names from being options")
    func gitCallsAreReadOnly() async throws {
        let git = FakeGit(answers: [
            "status": ProcessOutput(status: 0, standardOutput: Data("# branch.head 12-fix\n1 .M x\n".utf8)),
            "--left-right": ProcessOutput(status: 0, standardOutput: Data("14\t2\n".utf8)),
            "--count": ProcessOutput(status: 0, standardOutput: Data("674\n".utf8)),
        ])
        let checkout = Checkout(path: "/tmp/ws/develop3/project", name: "develop3", baseBranch: "develop", folder: UUID())
        let reading = await GitReader(runner: git).read(checkout)

        #expect(reading == .read(CheckoutState(
            status: GitStatus(branch: "12-fix", changedFiles: 1), ahead: 2, behind: 14, localBaseBehind: 674)))
        let calls = await git.calls
        #expect(calls.count == 3)
        for call in calls {
            #expect(call.executable == "/usr/bin/git")
            #expect(Array(call.arguments.prefix(5)) == [
                "-C", "/tmp/ws/develop3/project", "--no-optional-locks", "-c", "core.fsmonitor=false",
            ])
            #expect(!call.arguments.contains { ["fetch", "pull", "checkout", "reset", "stash", "gc"].contains($0) })
        }
        #expect(calls[1].arguments.suffix(2) == ["--end-of-options", "origin/develop...HEAD"])
        #expect(calls[2].arguments.suffix(2) == ["--end-of-options", "develop..origin/develop"])
    }

    @Test("WS-02 reads a real repository without touching its index")
    func readsRealRepository() async throws {
        let folder = try TemporaryFolder()
        let repo = folder.url.resolvingSymlinksInPath().appending(path: "develop1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let path = repo.path(percentEncoded: false)
        func git(_ arguments: String...) async throws {
            let output = try await SystemProcessRunner().run(
                GitReader.git,
                arguments: ["-C", path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Test",
                            "-c", "user.email=test@example.com"] + arguments,
                input: nil, timeout: .seconds(20))
            #expect(output.status == 0, "git \(arguments.joined(separator: " ")) failed")
        }
        try await git("init", "-q", "-b", "develop")
        try "one\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try await git("add", "a.txt")
        try await git("commit", "-q", "-m", "one")
        // origin/develop one commit past the local develop, as after a fetch.
        try await git("checkout", "-q", "-b", "upstream")
        try "upstream\n".write(to: repo.appending(path: "c.txt"), atomically: true, encoding: .utf8)
        try await git("add", "c.txt")
        try await git("commit", "-q", "-m", "upstream")
        try await git("update-ref", "refs/remotes/origin/develop", "HEAD")
        try await git("checkout", "-q", "develop")
        try await git("branch", "-q", "-D", "upstream")
        try await git("checkout", "-q", "-b", "1234-fix-login")
        try "two\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        let index = repo.appending(path: ".git/index")
        let before = try Data(contentsOf: index)
        let checkout = Checkout(path: path, name: "develop1", baseBranch: "develop", folder: UUID())

        let reading = await GitReader(runner: SystemProcessRunner()).read(checkout)

        let state = try #require(reading.state)
        #expect(state.status == GitStatus(branch: "1234-fix-login", changedFiles: 1, untrackedFiles: 1))
        #expect(state.ahead == 0)
        #expect(state.behind == 1)
        #expect(state.localBaseBehind == 1)
        #expect(!state.isFree(baseBranch: "develop"))
        #expect(try Data(contentsOf: index) == before)
        #expect(!FileManager.default.fileExists(atPath: repo.appending(path: ".git/index.lock").path(percentEncoded: false)))
    }

    @Test("WS-02 a tool past its time limit is ended")
    func endsSlowTool() async throws {
        let start = Date()
        await #expect(throws: ProcessTimedOut.self) {
            _ = try await SystemProcessRunner().run(
                URL(filePath: "/bin/sleep"), arguments: ["10"], input: nil, timeout: .milliseconds(200))
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    // MARK: - WS-03 Free

    @Test(
        "WS-03 a checkout is free when clean on its base branch",
        arguments: [
            (GitStatus(branch: "develop"), true),
            (GitStatus(branch: "develop", changedFiles: 1), false),
            (GitStatus(branch: "develop", untrackedFiles: 1), false),
            (GitStatus(branch: "1234-fix"), false),
            (GitStatus(branch: nil), false),
            (GitStatus(branch: "main"), false),
        ])
    func freeRule(status: GitStatus, free: Bool) {
        // Behind origin doesn't matter: the next task starts from origin/<base>.
        #expect(CheckoutState(status: status, ahead: 0, behind: 674, localBaseBehind: 674).isFree(baseBranch: "develop") == free)
    }

    @Test("WS-03 warns of a local base far behind origin")
    func staleBase() {
        #expect(CheckoutState(status: GitStatus(branch: "develop"), localBaseBehind: 674).hasStaleBase)
        #expect(!CheckoutState(status: GitStatus(branch: "develop"), localBaseBehind: 12).hasStaleBase)
        #expect(!CheckoutState(status: GitStatus(branch: "develop"), localBaseBehind: nil).hasStaleBase)
    }

    // MARK: - WS-04 The task of a checkout

    @Test(
        "WS-04 the branch's leading number is the work item's",
        arguments: [
            ("1234-fix-login-timeout", 1234), ("1234", 1234), ("1234_fix", 1234), ("feature/1234-fix", 1234),
            ("jdoe/77-x", 77), ("develop", nil), ("v2-cleanup", nil), ("2fa-login", nil), ("0-x", nil),
            ("release/2026.1", nil), ("12345678901-x", nil),
        ] as [(String, Int?)])
    func branchNumber(branch: String, number: Int?) {
        #expect(BranchTask.number(of: branch) == number)
    }

    @Test("WS-04 a branch's slug made readable")
    func readableSlug() {
        #expect(BranchTask.readableTitle(of: "1302-export-audit-log-as-csv") == "Export audit log as csv")
        #expect(BranchTask.readableTitle(of: "feature/0042_dark_mode") == "Dark mode")
        #expect(BranchTask.readableTitle(of: "1302") == nil)
        #expect(BranchTask.readableTitle(of: "develop") == nil)
    }

    @Test("WS-04 joins the branch with its work item, merge request and build")
    func matchesTask() throws {
        let now = Date()
        func item(_ reference: String, _ title: String) -> WorkItem {
            WorkItem(reference: reference, title: title, webURL: URL(string: "https://gitlab.example.com/\(reference)")!, updatedAt: now)
        }
        var mergeRequest = MergeRequest(
            iid: 87, title: "Fix login", webURL: URL(string: "https://gitlab.example.com/group/project/-/merge_requests/87")!,
            reference: "group/project!87", author: MergeRequest.Person(username: "jdoe", name: "Jane Doe"), updatedAt: now,
            roles: [.authored], sourceBranch: "1234-fix-login")
        let build = Build(
            job: "MR-87", number: 12, gitLabURL: mergeRequest.webURL, kind: .mine,
            phase: .finished(result: .success, duration: 60), startedAt: now)
        let otherProject = item("group/other#1234", "Another project's item")
        let mine = item("group/project#1234", "Fix the login timeout")

        let task = WorkspaceTask.match(
            branch: "1234-fix-login", workItems: [otherProject, mine], mergeRequests: [mergeRequest], builds: [build])
        #expect(task.number == 1234)
        #expect(task.workItem == mine)
        #expect(task.title == "Fix the login timeout")
        #expect(task.mergeRequest == mergeRequest)
        #expect(task.build == build)
        #expect(task.workItemURL == mine.webURL)

        // Unknown work item: the slug as the title, the issue link next to the merge request's.
        let unknown = WorkspaceTask.match(branch: "1234-fix-login", workItems: [], mergeRequests: [mergeRequest], builds: [])
        #expect(unknown.title == "Fix login")
        #expect(unknown.workItemURL?.absoluteString == "https://gitlab.example.com/group/project/-/issues/1234")

        // Another branch has no merge request; a detached HEAD has no task.
        mergeRequest.sourceBranch = "999-other"
        #expect(WorkspaceTask.match(branch: "1234-fix-login", workItems: [], mergeRequests: [mergeRequest], builds: []).mergeRequest == nil)
        #expect(WorkspaceTask.match(branch: nil, workItems: [mine], mergeRequests: [], builds: []) == WorkspaceTask())
    }

    // MARK: - WS-05 Open in IDE

    @Test(
        "WS-05 splits the IDE command into words without a shell",
        arguments: [
            ("code {path}", ["code", "{path}"]),
            ("  idea   {path} ", ["idea", "{path}"]),
            ("\"/Applications/My IDE.app/bin/ide\" --open '{path}'", ["/Applications/My IDE.app/bin/ide", "--open", "{path}"]),
            ("tool open\\ it", ["tool", "open it"]),
            ("echo $(rm -rf ~); ls | cat", ["echo", "$(rm", "-rf", "~);", "ls", "|", "cat"]),
            ("tool \"\"", ["tool", ""]),
            ("", []),
            ("tool 'unclosed", nil),
        ] as [(String, [String]?)])
    func splitsWords(line: String, words: [String]?) {
        #expect(LaunchCommand.words(of: line) == words)
    }

    @Test("WS-05 each placeholder stays one argument")
    func placeholdersStayOneArgument() {
        let path = "/Users/jdoe/my work/develop3; rm -rf ~/project"
        let command = LaunchCommand.make("ide open {name} --path={path} -f {path}", name: "develop 3", path: path)
        #expect(command == LaunchCommand(program: "ide", arguments: ["open", "develop 3", "--path=\(path)", "-f", path]))
        #expect(LaunchCommand.make("   ", name: "a", path: "/b") == nil)
    }

    @Test("WS-05 Open in IDE runs the user's program, shows its last line when it fails and logs only name and exit code")
    @MainActor
    func opensInIDE() async throws {
        let defaults = TemporaryDefaults()
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url, now: { Date() })
        let launcher = FakeLauncher(outcome: .exited(status: 2, lastLine: "ide: no workspace named develop3"))
        let store = WorkspacesStore(
            defaults: defaults.defaults, runner: FakeGit(), launcher: launcher, log: log, home: folder.url)
        let checkout = Checkout(path: "/Users/jdoe/my work/develop3", name: "develop3", baseBranch: "develop", folder: UUID())

        // No command: nothing runs.
        await store.openInIDE(checkout)
        #expect(await launcher.calls.isEmpty)
        #expect(store.actionProblems[checkout.id] != nil)

        store.update(RepositorySettings(ideCommand: "/bin/echo open {name} {path}"))
        await store.openInIDE(checkout)
        let call = try #require(await launcher.calls.first)
        #expect(call.program == "/bin/echo")
        #expect(call.arguments == ["open", "develop3", "/Users/jdoe/my work/develop3"])
        #expect(store.actionProblems[checkout.id] == "ide: no workspace named develop3")

        // A program that isn't there is never run.
        store.update(RepositorySettings(ideCommand: "/nowhere/ide {path}"))
        await store.openInIDE(checkout)
        #expect(await launcher.calls.count == 1)
        #expect(store.actionProblems[checkout.id]?.hasPrefix("Couldn't find ide") == true)

        try await Task.sleep(for: .milliseconds(200))
        let text = await log.entries().map(\.message).joined(separator: "\n")
        #expect(text.contains("echo exited with 2"))
        #expect(!text.contains("my work"))
        #expect(!text.contains("no workspace named"))
    }
}

/// A git that answers by the first argument it knows, and records every call.
private actor FakeGit: ProcessRunner {
    struct Call: Sendable {
        var executable: String
        var arguments: [String]
    }

    private let answers: [String: ProcessOutput]
    private(set) var calls: [Call] = []

    init(answers: [String: ProcessOutput] = [:]) {
        self.answers = answers
    }

    func run(_ executable: URL, arguments: [String], input: Data?) async throws -> ProcessOutput {
        calls.append(Call(executable: executable.path(percentEncoded: false), arguments: arguments))
        for key in ["status", "--left-right", "--count"] where arguments.contains(key) {
            if let answer = answers[key] {
                return answer
            }
        }
        return ProcessOutput(status: 128, standardError: Data("fatal: unknown\n".utf8))
    }
}

/// A launcher that records what it would start.
private actor FakeLauncher: ProgramLauncher {
    struct Call: Sendable {
        var program: String
        var arguments: [String]
    }

    private let outcome: LaunchOutcome
    private(set) var calls: [Call] = []

    init(outcome: LaunchOutcome) {
        self.outcome = outcome
    }

    func launch(
        _ program: URL, arguments: [String], directory: URL?, path: [String]?, wait: Duration
    ) async throws -> LaunchOutcome {
        calls.append(Call(program: program.path(percentEncoded: false), arguments: arguments))
        return outcome
    }
}
