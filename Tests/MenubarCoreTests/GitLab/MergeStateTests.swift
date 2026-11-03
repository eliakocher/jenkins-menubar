import Foundation
import Testing

@testable import MenubarCore

/// Merging from the app (MR-16): GitLab's merge state and checks, the card's headline and actions per state, and the
/// requests of merge, auto-merge, cancel, rebase and mark ready. Fixtures only, never a real GitLab.
@Suite("Merge from the app")
@MainActor
struct MergeStateTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    private nonisolated static let updatedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private nonisolated static let source = DescriptionSource(
        kind: .mergeRequest, reference: "group/project!16", webURL: gitLab.appending(path: "group/project/-/merge_requests/16"),
        updatedAt: updatedAt)

    private nonisolated static var mergeRequest: MergeRequest {
        MergeRequest(
            iid: 16, title: "Add a retry", webURL: source.webURL, reference: source.reference,
            author: .init(username: "me", name: "Jane Doe"), updatedAt: updatedAt, roles: [.authored])
    }

    private nonisolated static func decode(_ fixture: String) throws -> MergeState {
        let operation = try #require(GitLabOperation<MergeState>.mergeState(of: source))
        return try operation.decode(FixtureFiles.data("GitLab/\(fixture)"))
    }

    private nonisolated static func checks(_ failing: [String: String] = [:]) -> [MergeState.GitLabCheck] {
        ["NOT_APPROVED", "CI_MUST_PASS", "DISCUSSIONS_NOT_RESOLVED", "DRAFT_STATUS", "CONFLICT", "NEED_REBASE"].map {
            MergeState.GitLabCheck(identifier: $0, status: failing[$0] ?? "SUCCESS")
        }
    }

    // MARK: - Reading

    @Test("MR-16 reads the merge state, GitLab's checks and the project's rules")
    func decodesOpenState() throws {
        let state = try Self.decode("merge-state.json")

        #expect(state.lifecycle == .opened && !state.isDraft && state.status == .notApproved)
        #expect(state.headSHA == "4f2a9c1e5b7d3a8f0c6e2b9d1a4f7c3e5b8d0a2f")
        #expect(state.sourceBranch == "feature/export-retry" && state.targetBranch == "develop")
        #expect(state.commitCount == 3 && state.isBehind && state.behindCount == nil && !state.hasConflicts)
        #expect(state.pipelineStatus == .running)
        #expect(state.squash == .optional(on: true))
        // The merge request says nothing, so the project's default deletes the branch.
        #expect(state.removesSourceBranch)
        #expect(state.defaultSquashMessage == "Add a retry to the export job")
        #expect(state.defaultMergeMessage?.hasPrefix("Merge branch 'feature/export-retry' into 'develop'") == true)
        #expect(state.autoMerge == nil && state.autoMergeStrategy == "MERGE_WHEN_CHECKS_PASS")
        #expect(state.checks?.count == 10 && state.checks?.first == .init(identifier: "NOT_APPROVED", status: "FAILED"))
        #expect(state.permissions == .all && !state.fastForwardOnly)
    }

    @Test("MR-16 a merged answer, and one without GitLab's checks, decode with their squash rule and people")
    func decodesMergedAndBasic() throws {
        let merged = try Self.decode("merge-state-merged.json")
        #expect(merged.lifecycle == .merged && merged.mergedBy?.name == "Alex Kim" && merged.mergedAt != nil)
        #expect(merged.squash == .always && merged.fastForwardOnly)
        #expect(merged.permissions.canMerge == false && merged.autoMergeStrategy == nil)

        let basic = try Self.decode("merge-state-basic.json")
        #expect(basic.checks == nil && basic.isDraft && basic.status == .draftStatus)
        #expect(basic.squash == .never && basic.removesSourceBranch == false)
        #expect(basic.autoMerge == .init(strategy: "merge_when_checks_pass", setBy: .init(username: "slee", name: "Sam Lee")))
        #expect(basic.mergedBy == nil && basic.pipelineStatus == nil)
        // Without GitLab's checks, the status names the one that fails.
        let overview = MergeOverview(basic)
        #expect(overview.open.map(\.kind) == [.draft] && overview.open.first?.fix == .markReady)
    }

    // MARK: - The rules

    /// A state of !16 for the rules: ready unless changed.
    private nonisolated static func state(_ change: (inout MergeState) -> Void = { _ in }) -> MergeState {
        var state = MergeState(
            status: .mergeable, checks: checks(), headSHA: "4f2a9c1e", sourceBranch: "feature/export-retry",
            targetBranch: "develop", commitCount: 1, pipelineStatus: .success, autoMergeStrategies: ["merge_when_checks_pass"])
        change(&state)
        return state
    }

    nonisolated static let cases: [(String, MergeState, String, MergeOverview.Tone, [MergeAction])] = [
        ("ready", state(), "Ready to Merge", .ready, [.merge]),
        ("blocked", state {
            $0.status = .notApproved
            $0.checks = checks(["NOT_APPROVED": "FAILED", "DISCUSSIONS_NOT_RESOLVED": "FAILED"])
        }, "Blocked: 2 checks", .blocked, [.setAutoMerge]),
        ("pipeline pending", state {
            $0.status = .ciStillRunning
            $0.checks = checks(["CI_MUST_PASS": "FAILED"])
            $0.pipelineStatus = .running
        }, "Waiting for the pipeline", .waiting, [.setAutoMerge]),
        ("auto-merge on", state {
            $0.status = .ciStillRunning
            $0.checks = checks(["CI_MUST_PASS": "CHECKING"])
            $0.autoMerge = .init(strategy: "merge_when_checks_pass", setBy: .init(username: "slee", name: "Sam Lee"))
        }, "Auto-merge on", .autoMerge, [.cancelAutoMerge]),
        ("conflicts", state {
            $0.status = .conflict
            $0.checks = checks(["CONFLICT": "FAILED"])
            $0.hasConflicts = true
            $0.isBehind = true
            $0.autoMergeStrategies = []
        }, "Blocked: 1 check", .blocked, []),
        ("behind, fast-forward only", state {
            $0.status = .needRebase
            $0.checks = checks(["NEED_REBASE": "FAILED"])
            $0.isBehind = true
            $0.fastForwardOnly = true
            $0.autoMergeStrategies = []
        }, "Blocked: 1 check", .blocked, [.rebase]),
        ("behind, merge commits", state { $0.isBehind = true; $0.behindCount = 40 }, "Ready to Merge", .ready, [.merge, .rebase]),
        ("rebasing", state {
            $0.status = .needRebase
            $0.checks = checks(["NEED_REBASE": "FAILED"])
            $0.isBehind = true
            $0.isRebasing = true
            $0.autoMergeStrategies = []
        }, "Rebasing…", .waiting, []),
        ("draft", state {
            $0.status = .draftStatus
            $0.isDraft = true
            $0.checks = checks(["DRAFT_STATUS": "FAILED"])
        }, "Blocked: 1 check", .blocked, [.setAutoMerge, .markReady]),
        ("draft, no right to edit", state {
            $0.status = .draftStatus
            $0.checks = checks(["DRAFT_STATUS": "FAILED"])
            $0.permissions = .init(canMerge: false, canPushToSource: false, canUpdate: false, canRemoveSourceBranch: false)
        }, "Blocked: 1 check", .blocked, []),
        ("merged", state {
            $0.lifecycle = .merged
            $0.mergedBy = .init(username: "akim", name: "Alex Kim")
        }, "Merged", .merged, []),
        ("closed", state { $0.lifecycle = .closed }, "Closed", .neutral, []),
        ("checking", state {
            $0.status = .checking
            $0.checks = checks(["CI_MUST_PASS": "CHECKING"])
        }, "Checking…", .neutral, [.setAutoMerge]),
        ("no head commit", state { $0.headSHA = nil }, "Ready to Merge", .ready, []),
    ]

    @Test("MR-16 the headline and the actions per state", arguments: cases)
    func headlineAndActions(_ name: String, state: MergeState, title: String, tone: MergeOverview.Tone, actions: [MergeAction]) {
        let overview = MergeOverview(state, approvals: "1 of 2 approvals", openThreads: 3)

        #expect(overview.headline.title == title, "\(name)")
        #expect(overview.headline.tone == tone, "\(name)")
        #expect(overview.actions == actions, "\(name)")
    }

    @Test("MR-16 the open checks come first with their fix; inactive and not-open checks are left out")
    func checksAndFixes() throws {
        let state = try Self.decode("merge-state.json")
        let overview = MergeOverview(state, approvals: "1 of 2 approvals", openThreads: 0)

        // Failed, then pending (the running pipeline), then the warnings: GitLab's and behind the target branch.
        #expect(overview.open.map(\.title) == [
            "1 of 2 approvals", "Pipeline running", "External status checks must pass", "Behind develop",
        ])
        #expect(overview.open.map(\.status) == [.failed, .pending, .warning, .warning])
        #expect(overview.open.map(\.fix) == [.assignReviewers, .showBuild, .openInGitLab, .rebase])
        #expect(overview.passed.map(\.kind) == [.threads, .draft, .conflicts])
        #expect(overview.headline.title == "Blocked: 1 check" && overview.headline.detail == "Waiting for approvals")
        #expect(MergeOverview(state, approvals: "1 of 2 approvals").actions == [.setAutoMerge, .rebase])

        var several = state
        several.checks = Self.checks(["NOT_APPROVED": "FAILED", "CI_MUST_PASS": "FAILED", "CONFLICT": "FAILED"])
        several.pipelineStatus = .failed
        let blocked = MergeOverview(several, openThreads: 2)
        #expect(blocked.headline.title == "Blocked: 3 checks")
        #expect(blocked.headline.detail == "Approvals, the pipeline and conflicts")
        #expect(blocked.open.map(\.title).prefix(3) == ["Approvals required", "Pipeline failed", "Merge conflicts"])
        #expect(blocked.open.first { $0.kind == .conflicts }?.fix == .openConflicts)
    }

    @Test("MR-16 the summary counts the commits, the squash and the merge commit", arguments: [
        (3, false, false, "3 commits and 1 merge commit into develop"),
        (1, false, false, "1 commit and 1 merge commit into develop"),
        (4, true, false, "1 commit (4 squashed) and 1 merge commit into develop"),
        (2, false, true, "2 commits into develop"),
        (2, true, true, "1 commit (2 squashed) into develop"),
    ])
    func summary(commits: Int, squash: Bool, fastForward: Bool, expected: String) {
        let state = Self.state {
            $0.commitCount = commits
            $0.fastForwardOnly = fastForward
        }
        #expect(state.summary(squash: squash) == expected)
    }

    // MARK: - The requests

    private nonisolated static func body(_ request: HTTPRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private nonisolated static func input(_ request: HTTPRequest) throws -> [String: Any] {
        try #require((try body(request)["variables"] as? [String: Any])?["input"] as? [String: Any])
    }

    @Test("MR-16 merge sends the head sha and the options, auto-merge its strategy, and the token only in the header")
    func acceptRequests() async throws {
        let stub = StubTransport()
        let ok = #"{"data":{"mergeRequestAccept":{"errors":[],"mergeRequest":{"state":"merged","autoMergeEnabled":false}}}}"#
        stub.answer(operation: "MergeRequestAccept", body: ok)
        stub.answer(operation: "MergeRequestAutoMerge", body: ok)
        let client = GitLabClient(transport: stub, gitLab: Self.gitLab, token: "glpat-test")

        let options = MergeOptions(squash: true, removeSourceBranch: false, commitMessage: "Merge it", squashMessage: "Add a retry")
        try await client.send(try #require(GitLabOperation<Void>.accept(Self.source, sha: "4f2a9c1e", options: options)))
        let merge = try #require(stub.requests(operation: "MergeRequestAccept").first)
        #expect(merge.method == "POST" && merge.url.absoluteString == "https://gitlab.example.com/api/graphql")
        #expect(merge.headers["Authorization"] == "Bearer glpat-test")
        #expect((try Self.body(merge)["query"] as? String)?.contains("mergeRequestAccept(input: $input)") == true)
        let input = try Self.input(merge)
        #expect(input["projectPath"] as? String == "group/project" && input["iid"] as? String == "16")
        #expect(input["sha"] as? String == "4f2a9c1e")
        #expect(input["squash"] as? Bool == true && input["shouldRemoveSourceBranch"] as? Bool == false)
        #expect(input["commitMessage"] as? String == "Merge it" && input["squashCommitMessage"] as? String == "Add a retry")
        #expect(input["strategy"] == nil)
        #expect(String(decoding: merge.body ?? Data(), as: UTF8.self).contains("glpat-test") == false)

        let plain = MergeOptions(squash: false, removeSourceBranch: true, squashMessage: "ignored without a squash")
        try await client.send(
            try #require(GitLabOperation<Void>.accept(Self.source, sha: "4f2a9c1e", options: plain, strategy: "MERGE_WHEN_CHECKS_PASS")))
        let auto = try Self.input(try #require(stub.requests(operation: "MergeRequestAutoMerge").first))
        #expect(auto["strategy"] as? String == "MERGE_WHEN_CHECKS_PASS")
        #expect(auto["squash"] as? Bool == false && auto["shouldRemoveSourceBranch"] as? Bool == true)
        // GitLab's default messages go unless the user wrote their own.
        #expect(auto["commitMessage"] == nil && auto["squashCommitMessage"] == nil)
    }

    @Test("MR-16 cancel and rebase are REST calls on the merge request; cancel falls back to cancel_auto_merge")
    func restRequests() async throws {
        let stub = StubTransport()
        let base = "/api/v4/projects/group%2Fproject/merge_requests/16"
        stub.answer("PUT", path: "\(base)/rebase", status: 202, body: #"{"rebase_in_progress":true}"#)
        stub.answer("POST", path: "\(base)/cancel_merge_when_pipeline_succeeds", status: 201, body: "{}")
        let client = GitLabClient(transport: stub, gitLab: Self.gitLab, token: "glpat-test")

        try await client.rebase(Self.source)
        try await client.cancelAutoMerge(Self.source)

        let rebase = try #require(stub.requests(path: "\(base)/rebase").first)
        #expect(rebase.method == "PUT" && rebase.body == nil && rebase.headers["Authorization"] == "Bearer glpat-test")
        #expect(rebase.url.absoluteString.contains("glpat") == false)
        #expect(stub.requests(path: "\(base)/cancel_merge_when_pipeline_succeeds").map(\.method) == ["POST"])
        #expect(stub.requests(path: "\(base)/cancel_auto_merge").isEmpty)

        // A GitLab without the old endpoint takes its successor.
        let newer = StubTransport()
        newer.answer("POST", path: "\(base)/cancel_merge_when_pipeline_succeeds", status: 404, body: #"{"error":"404 Not Found"}"#)
        newer.answer("POST", path: "\(base)/cancel_auto_merge", status: 201, body: "{}")
        try await GitLabClient(transport: newer, gitLab: Self.gitLab, token: "glpat-test").cancelAutoMerge(Self.source)
        #expect(newer.requests(path: "\(base)/cancel_auto_merge").count == 1)

        // GitLab's words come back.
        let refused = StubTransport()
        refused.answer("PUT", path: "\(base)/rebase", status: 403, body: #"{"message":"Cannot push to source branch"}"#)
        await #expect(throws: GitLabError(.graphQLErrors(messages: ["Cannot push to source branch"]))) {
            try await GitLabClient(transport: refused, gitLab: Self.gitLab, token: "glpat-test").rebase(Self.source)
        }
    }

    @Test("MR-16 mark as ready sends mergeRequestSetDraft, and a payload's errors are GitLab's words")
    func setDraftRequest() async throws {
        let stub = StubTransport()
        stub.answer(operation: "MergeRequestSetDraft", body: #"{"data":{"mergeRequestSetDraft":{"errors":["Draft can't be changed"]}}}"#)
        let client = GitLabClient(transport: stub, gitLab: Self.gitLab, token: "glpat-test")

        let operation = try #require(GitLabOperation<Void>.setDraft(Self.source, draft: false))
        await #expect(throws: GitLabError(.graphQLErrors(messages: ["Draft can't be changed"]))) {
            try await client.send(operation)
        }
        let input = try Self.input(try #require(stub.requests(operation: "MergeRequestSetDraft").first))
        #expect(input["draft"] as? Bool == false && input["iid"] as? String == "16")
    }

    // MARK: - The store

    @Test("MR-16 the store loads once per update, asks without GitLab's checks when it refuses them, and adds the commits behind")
    func storeLoads() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        stub.answer(operation: "MergeRequestMergeState", body: try FixtureFiles.string("GitLab/merge-state.json"))
        stub.answer(operation: "MergeRequestMergeState", times: 1, body: try FixtureFiles.string("GitLab/merge-state-unknown-field.json"))
        stub.answer("GET", path: "/api/v4/projects/group%2Fproject/merge_requests/16", body: #"{"iid":16,"diverged_commits_count":40}"#)
        let store = MergeRequestMergeStore(services: try Self.services(stub: stub, folder: folder))

        await store.load(Self.mergeRequest)
        await store.load(Self.mergeRequest)

        let requests = stub.requests(operation: "MergeRequestMergeState")
        #expect(requests.count == 2)
        let queries = try requests.map { try Self.body($0)["query"] as? String ?? "" }
        #expect(queries[0].contains("mergeabilityChecks") && !queries[1].contains("mergeabilityChecks"))
        let state = try #require(store.load(of: Self.mergeRequest).state)
        #expect(state.behindCount == 40)
        let behind = try #require(stub.requests(path: "/api/v4/projects/group%2Fproject/merge_requests/16").first)
        #expect(behind.url.query == "include_diverged_commits_count=true")

        // The next merge request is asked without the checks at once.
        var other = Self.mergeRequest
        other.reference = "group/project!17"
        other.webURL = Self.gitLab.appending(path: "group/project/-/merge_requests/17")
        await store.load(other)
        #expect(stub.requests(operation: "MergeRequestMergeState").count == 3)
        #expect((try Self.body(stub.requests(operation: "MergeRequestMergeState")[2])["query"] as? String)?.contains("mergeabilityChecks") == false)
    }

    @Test("MR-16 a rebase is looked at until GitLab is done, then the details load again; a refusal shows GitLab's words")
    func storeRebases() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        let open = try FixtureFiles.string("GitLab/merge-state.json")
        stub.answer(operation: "MergeRequestMergeState", body: open)
        stub.answer("GET", path: "/api/v4/projects/group%2Fproject/merge_requests/16", body: #"{"diverged_commits_count":40}"#)
        stub.answer(operation: "MergeRequestDetails", body: try FixtureFiles.string("GitLab/merge-request-details.json"))
        let details = MergeRequestDetailsStore(services: try Self.services(stub: stub, folder: folder))
        let store = details.merge
        store.pollInterval = .zero
        await store.load(Self.mergeRequest)

        stub.answer("PUT", path: "/api/v4/projects/group%2Fproject/merge_requests/16/rebase", status: 202, body: #"{"rebase_in_progress":true}"#)
        let rebasing = open.replacingOccurrences(of: #""rebaseInProgress": false"#, with: #""rebaseInProgress": true"#)
        stub.answer(operation: "MergeRequestMergeState", times: 2, body: rebasing)
        await store.perform(.rebase, on: Self.mergeRequest)

        #expect(store.activity(of: Self.mergeRequest) == .succeeded(.rebase))
        // The load right after the request and one more look while it rebased, then the done one.
        #expect(stub.requests(operation: "MergeRequestMergeState").count == 4)
        #expect(store.load(of: Self.mergeRequest).state?.isRebasing == false)
        #expect(stub.requests(operation: "MergeRequestDetails").count == 1)

        // A merge without GitLab's head commit sends nothing.
        let noHead = open.replacingOccurrences(of: #""diffHeadSha": "4f2a9c1e5b7d3a8f0c6e2b9d1a4f7c3e5b8d0a2f""#, with: #""diffHeadSha": null"#)
        stub.answer(operation: "MergeRequestMergeState", body: noHead)
        await store.load(Self.mergeRequest, force: true)
        await store.perform(.merge, on: Self.mergeRequest)
        #expect(stub.requests(operation: "MergeRequestAccept").isEmpty)
        guard case .failed(.merge, _, needsToken: false) = store.activity(of: Self.mergeRequest) else {
            Issue.record("the merge didn't fail: \(store.activity(of: Self.mergeRequest))")
            return
        }

        // GitLab refuses the merge: its words, and Try Again sends it again.
        stub.answer(operation: "MergeRequestMergeState", body: open)
        await store.load(Self.mergeRequest, force: true)
        stub.answer(operation: "MergeRequestAccept", body: #"{"data":{"mergeRequestAccept":{"errors":["SHA does not match HEAD of source branch"],"mergeRequest":null}}}"#)
        await store.perform(.merge, on: Self.mergeRequest, options: MergeOptions(squash: false, removeSourceBranch: true))
        #expect(store.activity(of: Self.mergeRequest) == .failed(.merge, message: "SHA does not match HEAD of source branch", needsToken: false))
        let sent = try Self.input(try #require(stub.requests(operation: "MergeRequestAccept").first))
        #expect(sent["sha"] as? String == "4f2a9c1e5b7d3a8f0c6e2b9d1a4f7c3e5b8d0a2f")
        store.dismiss(Self.mergeRequest)
        #expect(store.activity(of: Self.mergeRequest) == .idle)
    }

    @Test("MR-16 without a token nothing is sent, and the outcome asks for one")
    func storeWithoutToken() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        let store = MergeRequestMergeStore(services: try Self.services(stub: stub, folder: folder, token: nil))

        await store.perform(.cancelAutoMerge, on: Self.mergeRequest)

        #expect(stub.requests.isEmpty)
        #expect(store.activity(of: Self.mergeRequest) == .failed(
            .cancelAutoMerge, message: Problem.noToken(.gitLab).message, needsToken: true))
        #expect(store.load(of: Self.mergeRequest).failed)
    }

    private static func services(stub: StubTransport, folder: TemporaryFolder, token: String? = "glpat-test") throws -> GitLabServices {
        let team = TeamStore(folder: folder.file("support"), report: { _ in })
        try team.save(Project(id: .main, team: TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: gitLab.absoluteString,
            gitLabProject: "group/project")))
        let values = token.map { [TokenAccount.gitlab.rawValue: $0] } ?? [:]
        return GitLabServices(
            transport: stub, clock: ContinuousClock(), tokens: TokenStore(keychain: InMemoryKeychain(values: values)), team: team,
            caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: ActivityLog(folder: folder.file("logs")))
    }
}
