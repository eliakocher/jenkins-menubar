import Foundation
import Testing

@testable import MenubarCore

/// The code changes of a selected merge request (MR-11).
@Suite("Merge request changes")
@MainActor
struct MergeRequestChangesTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    private nonisolated static let source = DescriptionSource(
        kind: .mergeRequest, reference: "group/subgroup/project!16",
        webURL: gitLab.appending(path: "group/subgroup/project/-/merge_requests/16"),
        updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    private nonisolated static let diffsPath = "/api/v4/projects/group%2Fsubgroup%2Fproject/merge_requests/16/diffs"

    private nonisolated static func client(_ stub: StubTransport) -> GitLabClient {
        GitLabClient(transport: stub, gitLab: gitLab, token: "secret-token")
    }

    @Test("MR-11 reads the hunks with their line numbers and the no-newline marker")
    func hunks() throws {
        let diff = """
            diff --git a/App.swift b/App.swift
            index 1111111..2222222 100644
            --- a/App.swift
            +++ b/App.swift
            @@ -10,4 +10,5 @@ final class App {
                 func run() {
            -        start()
            +        prepare()
            +        start()

                 }
            @@ -40 +41 @@
            -let limit = 2
            \\ No newline at end of file
            +let limit = 3
            \\ No newline at end of file
            diff --git a/Other.swift b/Other.swift

            """
        guard case .hunks(let hunks) = UnifiedDiff.parse(diff) else {
            Issue.record("no hunks")
            return
        }
        #expect(hunks.count == 2)
        #expect(hunks[0].section == "final class App {")
        #expect(hunks[0].header == "@@ -10,4 +10,5 @@")
        let first = hunks[0].lines
        #expect(first.map(\.kind) == [.context, .removed, .added, .added, .context, .context])
        #expect(first.map(\.oldNumber) == [10, 11, nil, nil, 12, 13])
        #expect(first.map(\.newNumber) == [10, nil, 11, 12, 13, 14])
        // An empty line in a hunk is an empty context line.
        #expect(first[4].text == "")
        #expect(first[1].text == "        start()")
        let second = hunks[1]
        #expect((second.oldStart, second.oldCount, second.newStart, second.newCount) == (40, 1, 41, 1))
        #expect(second.lines.map(\.noNewlineAtEnd) == [true, true])
        #expect(second.lines.map(\.newNumber) == [nil, 41])
    }

    @Test(
        "MR-11 binary, empty and left-out diffs show no lines",
        arguments: [
            ("Binary files a/icon.png and b/icon.png differ\n", MergeRequestChanges.FileChange.Content.binary),
            ("diff --git a/x b/x\nGIT binary patch\nliteral 12\n", .binary),
            ("", .empty),
            ("diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n", .empty),
        ])
    func noLines(_ diff: String, expected: MergeRequestChanges.FileChange.Content) {
        #expect(UnifiedDiff.parse(diff) == expected)
    }

    @Test("MR-11 reads GitLab's files: new, deleted, renamed, binary, generated and left out")
    func files() async throws {
        let stub = StubTransport()
        stub.answer("GET", path: Self.diffsPath, body: try FixtureFiles.string("GitLab/merge-request-diffs.json"))
        let page = try await Self.client(stub).diffsPage(of: Self.source, page: 1)
        let changes = MergeRequestChanges(files: page.files)

        let files = changes.files
        #expect(files.map(\.kind) == [.modified, .added, .deleted, .renamed, .modified, .modified, .modified])
        #expect(files.map(\.path)[2] == "Sources/Export/Old.swift")
        #expect(files[3].oldPath == "Sources/Export/Upload.swift" && files[3].newPath == "Sources/Export/Uploader.swift")
        #expect((files[0].additions, files[0].deletions) == (4, 2))
        #expect(files[3].content == .empty)
        #expect(files[4].content == .binary)
        // Collapsed and too large: GitLab sent no diff.
        #expect(files[5].content == .notShown && files[6].content == .notShown)
        // A lockfile by its name, a file GitLab marks as generated.
        #expect(files.map(\.isGenerated) == [false, false, false, false, false, true, true])
        #expect((changes.additions, changes.deletions, page.nextPage) == (6, 3, nil))

        let request = try #require(stub.requests.first)
        #expect(request.headers["Authorization"] == "Bearer secret-token")
        #expect(!request.url.absoluteString.contains("secret-token"))
        #expect(request.url.query() == "page=1&per_page=25")
    }

    @Test("MR-11 reads every changed path from GitLab's list, without the diffs", arguments: [3, 3001])
    func list(count: Int) async throws {
        let stub = StubTransport()
        stub.answer(operation: "MergeRequestDiffStats", body: Self.listBody(count: count))
        let operation = try #require(GitLabOperation.changedFiles(of: Self.source))
        let changes = try await Self.client(stub).send(operation)

        #expect(changes.files.count == count)
        #expect(changes.files[1].path == "src/f1.swift" && changes.files[1].kind == nil && changes.files[1].content == .notLoaded)
        #expect((changes.files[1].additions, changes.files[1].deletions) == (2, 1))
        #expect(changes.isComplete)
        // Over 3,000 files: the list only, and GitLab's page for the diffs.
        #expect(changes.isListOnly == (count > ChangesPaging.listOnlyAbove))
        #expect(stub.requests.first?.graphQL?.variables == #"{"path":"group/subgroup/project","iid":"16"}"#)
    }

    @Test("MR-11 diffs go to the listed files by path, whatever GitLab's order")
    func byPath() {
        func listed(_ path: String) -> MergeRequestChanges.FileChange {
            .init(oldPath: path, newPath: path, kind: nil, content: .notLoaded, additions: 7, deletions: 3)
        }
        func diff(_ old: String, _ new: String, _ kind: MergeRequestChanges.FileChange.Kind, _ text: String) -> MergeRequestChanges.FileChange {
            .init(oldPath: old, newPath: new, kind: kind, content: UnifiedDiff.parse(text))
        }
        var changes = MergeRequestChanges(files: ["a.swift", "b.swift", "c.png", "d.swift"].map(listed))
        changes.merge([
            diff("c.png", "c.png", .modified, "Binary files a/c.png and b/c.png differ\n"),
            diff("old/b.swift", "b.swift", .renamed, "@@ -1 +1 @@\n-x\n+y\n"),
            diff("e.swift", "e.swift", .added, "@@ -0,0 +1 @@\n+z\n"),
        ])

        #expect(changes.files.map(\.newPath) == ["a.swift", "b.swift", "c.png", "d.swift", "e.swift"])
        #expect(changes.files[1].kind == .renamed && changes.files[1].oldPath == "old/b.swift")
        #expect((changes.files[1].additions, changes.files[1].deletions) == (1, 1))
        // A diff without lines keeps the list's +/−; a file no page has brought yet waits.
        #expect(changes.files[2].content == .binary && changes.files[2].additions == 7)
        #expect(changes.files[0].content == .notLoaded && changes.files[0].additions == 7)

        // Once every page came, a file none of them had is left to GitLab's page.
        changes.settle()
        #expect(changes.files[0].content == .notShown && changes.files[3].content == .notShown)
    }

    @Test("MR-11 a file's diff loads with its page, once, and nothing loads on selection")
    func onDemand() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        Self.serve(stub, count: 60)
        let store = MergeRequestChangesStore(services: try Self.services(stub: stub, folder: folder))
        let mergeRequest = Self.mergeRequest(16)

        store.select(mergeRequest)
        #expect(stub.requests.isEmpty)

        // The card shows: the list, then the first page.
        await store.open(mergeRequest)
        #expect(stub.requests(operation: "MergeRequestDiffStats").count == 1)
        #expect(Self.pages(stub) == [1])
        #expect(store.state(of: mergeRequest).changes?.files[24].hunks.isEmpty == false)
        #expect(store.state(of: mergeRequest).changes?.files[25].content == .notLoaded)

        // A file of the third page, asked twice at once; then one on the second page, whose page half a page down is
        // the third, and one already loaded.
        async let first: Void = store.loadDiff(of: mergeRequest, fileAt: 55)
        async let second: Void = store.loadDiff(of: mergeRequest, fileAt: 56)
        _ = await (first, second)
        await store.loadDiff(of: mergeRequest, fileAt: 40)
        await store.loadDiff(of: mergeRequest, fileAt: 3)
        await store.open(mergeRequest)

        #expect(Self.pages(stub) == [1, 3, 2])
        #expect(stub.requests(operation: "MergeRequestDiffStats").count == 1)
        let state = store.state(of: mergeRequest)
        #expect(state.changes?.files.allSatisfy { !$0.hunks.isEmpty } == true)
        #expect(state.isLoadingDiffs == false)
    }

    @Test("MR-11 selecting another merge request cancels the loads on their way")
    func cancels() async throws {
        let folder = try TemporaryFolder()
        let clock = TestClock()
        let stub = StubTransport(clock: clock)
        Self.serve(stub, count: 30)
        // The first page of !1 takes long, once.
        stub.add(
            StubTransport.Route(
                matches: { $0.url.path().contains("merge_requests/1/diffs") }, delay: .seconds(10), times: 1
            ) { _ in .success(HTTPResponse(status: 200, body: Data("[]".utf8))) })
        let store = MergeRequestChangesStore(services: try Self.services(stub: stub, folder: folder))
        let slow = Self.mergeRequest(1)
        let other = Self.mergeRequest(2)

        let opening = Task { await store.open(slow) }
        await clock.waitForSleepers(1)
        #expect(store.state(of: slow).isLoadingDiffs)
        await store.open(other)
        await opening.value

        #expect(clock.sleeperCount == 0)
        #expect(store.state(of: slow).isLoadingDiffs == false && store.state(of: slow).failed == false)
        #expect(store.state(of: other).changes?.files.first?.hunks.isEmpty == false)

        // Back to !1: its page is asked again.
        await store.open(slow)
        #expect(store.state(of: slow).changes?.files.first?.hunks.isEmpty == false)
        #expect(stub.requests.filter { $0.url.path().contains("merge_requests/1/diffs") }.count == 2)
    }

    @Test("MR-11 keeps the lists of the last 5 merge requests and the diffs of the selected one")
    func bounded() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        Self.serve(stub, count: 3)
        let store = MergeRequestChangesStore(services: try Self.services(stub: stub, folder: folder))
        let mergeRequests = (1...6).map(Self.mergeRequest)

        for mergeRequest in mergeRequests {
            await store.open(mergeRequest)
        }

        #expect(store.state(of: mergeRequests[0]).changes == nil)
        for mergeRequest in mergeRequests[1...4] {
            let files = store.state(of: mergeRequest).changes?.files ?? []
            #expect(files.count == 3 && files.allSatisfy { $0.content == .notLoaded })
        }
        #expect(store.state(of: mergeRequests[5]).changes?.files.allSatisfy { !$0.hunks.isEmpty } == true)
        #expect(stub.requests(operation: "MergeRequestDiffStats").count == 6)

        // A kept list isn't asked again; its first page is.
        await store.open(mergeRequests[2])
        #expect(stub.requests(operation: "MergeRequestDiffStats").count == 6)
        #expect(store.state(of: mergeRequests[2]).changes?.files.allSatisfy { !$0.hunks.isEmpty } == true)
    }

    @Test(
        "MR-11 big and generated files start folded",
        arguments: [
            ("yarn.lock", 3, true),
            ("web/dist/app.min.js", 3, true),
            ("Sources/App.swift", 3, false),
            ("Sources/App.swift", 501, true),
        ])
    func folds(_ path: String, lines: Int, folds: Bool) {
        let hunk = DiffHunk(
            oldStart: 1, oldCount: 0, newStart: 1, newCount: lines,
            lines: (1...lines).map { DiffLine(kind: .added, text: "x", oldNumber: nil, newNumber: $0) })
        let file = MergeRequestChanges.FileChange(
            oldPath: path, newPath: path, kind: .modified, isGenerated: GeneratedFiles.isGenerated(path),
            content: .hunks([hunk]))
        #expect(file.foldsByDefault == folds)
    }

    // MARK: Helpers

    private nonisolated static func mergeRequest(_ iid: Int) -> MergeRequest {
        MergeRequest(
            iid: iid, title: "Change \(iid)", webURL: gitLab.appending(path: "group/project/-/merge_requests/\(iid)"),
            reference: "group/project!\(iid)", author: .init(username: "slee", name: "Sam Lee"),
            updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000), roles: [.authored])
    }

    /// GitLab's list of `count` paths, `src/f0.swift` on, each +2 −1.
    private nonisolated static func listBody(count: Int) -> String {
        let stats = (0..<count).map { #"{"path":"src/f\#($0).swift","additions":2,"deletions":1}"# }
        return #"{"data":{"project":{"mergeRequest":{"diffStats":[\#(stats.joined(separator: ","))]}}}}"#
    }

    /// Answers the list and the pages of diffs of any merge request with `count` files, 25 a page.
    private nonisolated static func serve(_ stub: StubTransport, count: Int) {
        stub.answer(operation: "MergeRequestDiffStats", body: listBody(count: count))
        stub.add(
            StubTransport.Route(matches: { $0.graphQL?.name == "MergeRequestDiffs" }) { request in
                let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let page = Int(query.first { $0.name == "page" }?.value ?? "") ?? 1
                let range = (page - 1) * 25..<min(count, page * 25)
                let files = range.map {
                    #"{"old_path":"src/f\#($0).swift","new_path":"src/f\#($0).swift","diff":"@@ -1 +1,2 @@\n-a\n+b\n+c\n"}"#
                }
                let pages = (count + 24) / 25
                var headers = ["X-Total-Pages": String(pages)]
                if page < pages {
                    headers["X-Next-Page"] = String(page + 1)
                }
                return .success(HTTPResponse(status: 200, headers: headers, body: Data("[\(files.joined(separator: ","))]".utf8)))
            })
    }

    /// the pages of diffs asked for, in order
    private nonisolated static func pages(_ stub: StubTransport) -> [Int] {
        stub.requests(operation: "MergeRequestDiffs").compactMap { request in
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
                .flatMap { Int($0) }
        }
    }

    /// GitLab on the stub, a token in a fake keychain, and the team values of `group/project`.
    private static func services(stub: StubTransport, folder: TemporaryFolder) throws -> GitLabServices {
        let team = TeamStore(folder: folder.file("support"), report: { _ in })
        try team.save(Project(id: .main, team: TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: gitLab.absoluteString,
            gitLabProject: "group/project")))
        return GitLabServices(
            transport: stub, clock: ContinuousClock(),
            tokens: TokenStore(keychain: InMemoryKeychain(values: [TokenAccount.gitlab.rawValue: "glpat-test"])), team: team,
            caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: ActivityLog(folder: folder.file("logs")))
    }
}
