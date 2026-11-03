import Foundation
import Testing

@testable import MenubarCore

/// Merging from the app (MR-16): GitLab's merge state and checks, the card's headline and actions per state, and the
/// requests of merge, auto-merge, cancel and mark ready. Fixtures only, never a real GitLab.
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
        // The merge request's own setting, as GitLab's widget starts its checkbox.
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
        // `shouldRemoveSourceBranch` false, `forceRemoveSourceBranch` true: GitLab's widget deletes it.
        #expect(basic.squash == .never && basic.removesSourceBranch == true)
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
            targetBranch: "develop", commitCount: 1, pipelineStatus: .success)
        change(&state)
        return state
    }

    nonisolated static let cases: [(String, MergeState, String, MergeOverview.Tone, [MergeAction])] = [
        ("ready", state(), "Ready to Merge", .ready, [.merge]),
        ("blocked", state {
            $0.status = .notApproved
            $0.checks = checks(["NOT_APPROVED": "FAILED", "DISCUSSIONS_NOT_RESOLVED": "FAILED"])
            $0.autoMergeStrategies = ["merge_when_checks_pass"]
        }, "Blocked: 2 checks", .blocked, [.setAutoMerge]),
        ("blocked, no auto-merge offered", state {
            $0.status = .notApproved
            $0.checks = checks(["NOT_APPROVED": "FAILED"])
        }, "Blocked: 1 check", .blocked, []),
        ("pipeline pending", state {
            $0.status = .ciStillRunning
            $0.checks = checks(["CI_MUST_PASS": "FAILED"])
            $0.pipelineStatus = .running
            $0.autoMergeStrategies = ["merge_when_checks_pass"]
        }, "Waiting for the pipeline", .waiting, [.setAutoMerge]),
        ("a merge train offered", state { $0.autoMergeStrategies = ["merge_when_checks_pass", "merge_train"] },
         "Ready to Merge", .ready, [.setAutoMerge]),
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
        }, "Blocked: 1 check", .blocked, []),
        ("behind, fast-forward only", state {
            $0.status = .needRebase
            $0.checks = checks(["NEED_REBASE": "FAILED"])
            $0.isBehind = true
            $0.fastForwardOnly = true
        }, "Blocked: 1 check", .blocked, []),
        ("behind, merge commits", state { $0.isBehind = true; $0.behindCount = 40 }, "Ready to Merge", .ready, [.merge]),
        ("merging", state { $0.isMerging = true }, "Merging…", .autoMerge, []),
        ("draft", state {
            $0.status = .draftStatus
            $0.isDraft = true
            $0.checks = checks(["DRAFT_STATUS": "FAILED"])
            $0.autoMergeStrategies = ["merge_when_checks_pass"]
        }, "Blocked: 1 check", .blocked, [.setAutoMerge, .markReady]),
        ("draft, no right to edit", state {
            $0.status = .draftStatus
            $0.checks = checks(["DRAFT_STATUS": "FAILED"])
            $0.permissions = .init(canMerge: false, canUpdate: false, canRemoveSourceBranch: false)
        }, "Blocked: 1 check", .blocked, []),
        ("merged", state {
            $0.lifecycle = .merged
            $0.mergedBy = .init(username: "akim", name: "Alex Kim")
        }, "Merged", .merged, []),
        ("closed", state { $0.lifecycle = .closed }, "Closed", .neutral, []),
        ("checking", state {
            $0.status = .checking
            $0.checks = checks(["CI_MUST_PASS": "CHECKING"])
        }, "Checking…", .neutral, []),
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

        // Failed, then pending (the running pipeline), then GitLab's warning, then behind the target branch, for the record.
        #expect(overview.open.map(\.title) == [
            "1 of 2 approvals", "Pipeline running", "External status checks must pass", "Behind develop",
        ])
        #expect(overview.open.map(\.status) == [.failed, .pending, .warning, .info])
        #expect(overview.open.map(\.fix) == [.assignReviewers, .showBuild, .openInGitLab, nil])
        #expect(overview.passed.map(\.kind) == [.threads, .draft, .conflicts])
        #expect(overview.headline.title == "Blocked: 1 check" && overview.headline.detail == "Waiting for approvals")
        #expect(MergeOverview(state, approvals: "1 of 2 approvals").actions == [.setAutoMerge])

        var several = state
        several.checks = Self.checks(["NOT_APPROVED": "FAILED", "CI_MUST_PASS": "FAILED", "CONFLICT": "FAILED"])
        several.pipelineStatus = .failed
        let blocked = MergeOverview(several, openThreads: 2)
        #expect(blocked.headline.title == "Blocked: 3 checks")
        #expect(blocked.headline.detail == "Approvals, the pipeline and conflicts")
        #expect(blocked.open.map(\.title).prefix(3) == ["Approvals required", "Pipeline failed", "Merge conflicts"])
        #expect(blocked.open.first { $0.kind == .conflicts }?.fix == .openConflicts)

        // A rebase GitLab requires is said, and left to GitLab.
        var fastForward = state
        fastForward.checks = Self.checks(["NEED_REBASE": "FAILED"])
        fastForward.behindCount = 40
        let needsRebase = try #require(MergeOverview(fastForward).open.first { $0.kind == .behind })
        #expect(needsRebase.title == "40 commits behind develop" && needsRebase.status == .failed && needsRebase.fix == .openInGitLab)
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

    @Test("MR-16 cancel is a REST call on the merge request, and falls back to cancel_auto_merge")
    func restRequests() async throws {
        let stub = StubTransport()
        let base = "/api/v4/projects/group%2Fproject/merge_requests/16"
        stub.answer("POST", path: "\(base)/cancel_merge_when_pipeline_succeeds", status: 201, body: "{}")
        let client = GitLabClient(transport: stub, gitLab: Self.gitLab, token: "glpat-test")

        try await client.cancelAutoMerge(Self.source)

        let cancel = try #require(stub.requests(path: "\(base)/cancel_merge_when_pipeline_succeeds").first)
        #expect(cancel.method == "POST" && cancel.body == nil && cancel.headers["Authorization"] == "Bearer glpat-test")
        #expect(cancel.url.absoluteString.contains("glpat") == false)
        #expect(stub.requests(path: "\(base)/cancel_auto_merge").isEmpty)

        // A GitLab without the old endpoint takes its successor.
        let newer = StubTransport()
        newer.answer("POST", path: "\(base)/cancel_merge_when_pipeline_succeeds", status: 404, body: #"{"error":"404 Not Found"}"#)
        newer.answer("POST", path: "\(base)/cancel_auto_merge", status: 201, body: "{}")
        try await GitLabClient(transport: newer, gitLab: Self.gitLab, token: "glpat-test").cancelAutoMerge(Self.source)
        #expect(newer.requests(path: "\(base)/cancel_auto_merge").count == 1)

        // GitLab's words come back.
        let refused = StubTransport()
        refused.answer(
            "POST", path: "\(base)/cancel_merge_when_pipeline_succeeds", status: 403,
            body: #"{"message":"You do not have permission to cancel the auto-merge"}"#)
        await #expect(throws: GitLabError(.graphQLErrors(messages: ["You do not have permission to cancel the auto-merge"]))) {
            try await GitLabClient(transport: refused, gitLab: Self.gitLab, token: "glpat-test").cancelAutoMerge(Self.source)
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

    @Test("MR-16 a merge GitLab runs in the background is looked at until done, then the details load again; a refusal shows GitLab's words")
    func storeMerges() async throws {
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

        let ok = #"{"data":{"mergeRequestAccept":{"errors":[],"mergeRequest":{"state":"opened","autoMergeEnabled":false}}}}"#
        stub.answer(operation: "MergeRequestAccept", times: 1, body: ok)
        let merged = open.replacingOccurrences(of: #""state": "opened""#, with: #""state": "merged""#)
        stub.answer(operation: "MergeRequestMergeState", body: merged)
        let merging = open.replacingOccurrences(of: #""mergeOngoing": false"#, with: #""mergeOngoing": true"#)
        stub.answer(operation: "MergeRequestMergeState", times: 2, body: merging)
        await store.perform(.merge, on: Self.mergeRequest)

        #expect(store.activity(of: Self.mergeRequest) == .succeeded(.merge))
        // The load right after the request and one more look while it merged, then the merged one.
        #expect(stub.requests(operation: "MergeRequestMergeState").count == 4)
        #expect(store.load(of: Self.mergeRequest).state?.lifecycle == .merged)
        #expect(stub.requests(operation: "MergeRequestDetails").count == 1)
        // GitLab's widget's defaults: the head sha, the merge request's branch choice and the project's squash, nothing else.
        let first = try Self.input(try #require(stub.requests(operation: "MergeRequestAccept").first))
        #expect(Set(first.keys) == ["projectPath", "iid", "sha", "squash", "shouldRemoveSourceBranch"])
        #expect(first["squash"] as? Bool == true && first["shouldRemoveSourceBranch"] as? Bool == true)

        // A merge without GitLab's head commit sends nothing.
        let noHead = open.replacingOccurrences(of: #""diffHeadSha": "4f2a9c1e5b7d3a8f0c6e2b9d1a4f7c3e5b8d0a2f""#, with: #""diffHeadSha": null"#)
        stub.answer(operation: "MergeRequestMergeState", body: noHead)
        await store.load(Self.mergeRequest, force: true)
        await store.perform(.merge, on: Self.mergeRequest)
        #expect(stub.requests(operation: "MergeRequestAccept").count == 1)
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
        let sent = try Self.input(try #require(stub.requests(operation: "MergeRequestAccept").last))
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

    // MARK: - The cache on disk

    @Test("MR-16 the merge state kept on disk shows at once, with its writes off until GitLab confirms it")
    func keptStateIsCheckingUntilConfirmed() async throws {
        let folder = try TemporaryFolder()
        let details = DetailCache(folder: folder.file("details"))
        let open = try FixtureFiles.string("GitLab/merge-state.json")
        let first = StubTransport()
        first.answer(operation: "MergeRequestMergeState", body: open)
        first.answer("GET", path: "/api/v4/projects/group%2Fproject/merge_requests/16", body: #"{"diverged_commits_count":40}"#)
        let firstStore = MergeRequestMergeStore(services: try Self.services(stub: first, folder: folder, details: details))
        await firstStore.load(Self.mergeRequest)
        #expect(firstStore.load(of: Self.mergeRequest).isChecking == false)

        // A relaunch, GitLab failing: the kept state shows, still unconfirmed, with the failure. A write sends nothing.
        let offline = StubTransport()
        offline.fail(operation: "MergeRequestMergeState", with: .cannotConnect)
        let store = MergeRequestMergeStore(services: try Self.services(stub: offline, folder: folder, details: details))
        #expect(store.load(of: Self.mergeRequest).state == nil)
        await store.load(Self.mergeRequest)
        var load = store.load(of: Self.mergeRequest)
        #expect(load.state?.headSHA == "4f2a9c1e5b7d3a8f0c6e2b9d1a4f7c3e5b8d0a2f" && load.state?.behindCount == 40)
        #expect(load.isCached && load.failed && load.isChecking)
        await store.perform(.merge, on: Self.mergeRequest)
        await store.perform(.markReady, on: Self.mergeRequest)
        #expect(offline.requests(operation: "MergeRequestAccept").isEmpty && offline.requests(operation: "MergeRequestSetDraft").isEmpty)
        guard case .failed(.markReady, _, needsToken: false) = store.activity(of: Self.mergeRequest) else {
            Issue.record("the write wasn't refused: \(store.activity(of: Self.mergeRequest))")
            return
        }
        store.dismiss(Self.mergeRequest)

        // Asked again, GitLab answers: confirmed, and the writes are on.
        let online = StubTransport()
        online.answer(operation: "MergeRequestMergeState", body: open)
        online.answer("GET", path: "/api/v4/projects/group%2Fproject/merge_requests/16", body: #"{"diverged_commits_count":41}"#)
        online.answer(operation: "MergeRequestAccept", body: #"{"data":{"mergeRequestAccept":{"errors":[],"mergeRequest":{"state":"opened"}}}}"#)
        let relaunched = MergeRequestMergeStore(services: try Self.services(stub: online, folder: folder, details: details))
        relaunched.pollInterval = .zero
        await relaunched.load(Self.mergeRequest)
        load = relaunched.load(of: Self.mergeRequest)
        #expect(load.state?.behindCount == 41 && !load.isCached && !load.failed && !load.isChecking)
        // Selected again, unchanged: nothing is asked.
        await relaunched.load(Self.mergeRequest)
        #expect(online.requests(operation: "MergeRequestMergeState").count == 1)
        await relaunched.perform(.merge, on: Self.mergeRequest)
        #expect(online.requests(operation: "MergeRequestAccept").count == 1)
    }

    @Test("MR-16 a kept merge state that no longer decodes is ignored, one without its optional fields decodes")
    func keptStateDecodes() throws {
        let folder = try TemporaryFolder()
        let details = DetailCache(folder: folder.file("details"))
        let state = try Self.decode("merge-state.json")
        details.save(state, updatedAt: Self.updatedAt, as: .mergeState, key: "group/project!16")
        #expect(details.load(.mergeState, key: "group/project!16")?.value == state)

        // The optional fields a cache from before them lacks.
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        for key in ["checks", "headSHA", "commitCount", "behindCount", "pipelineStatus", "defaultMergeMessage", "autoMerge", "mergedBy", "mergeError"] {
            object[key] = nil
        }
        let thin = try JSONDecoder().decode(MergeState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(thin.checks == nil && thin.headSHA == nil && thin.targetBranch == "develop")

        // A copy missing a field that isn't optional can't be read: the card shows its skeleton, as without a copy.
        let broken = DetailEntry(value: ["lifecycle": "opened"], updatedAt: nil, savedAt: .now)
        details.save(broken.value, updatedAt: nil, as: DetailKind<[String: String]>("merge-state"), key: "group/project!17")
        #expect(details.load(.mergeState, key: "group/project!17") == nil)
    }

    private static func services(
        stub: StubTransport, folder: TemporaryFolder, token: String? = "glpat-test", details: DetailCache? = nil
    ) throws -> GitLabServices {
        let team = TeamStore(folder: folder.file("support"), report: { _ in })
        try team.save(Project(id: .main, team: TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: gitLab.absoluteString,
            gitLabProject: "group/project")))
        let values = token.map { [TokenAccount.gitlab.rawValue: $0] } ?? [:]
        return GitLabServices(
            transport: stub, clock: ContinuousClock(), tokens: TokenStore(keychain: InMemoryKeychain(values: values)), team: team,
            caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: ActivityLog(folder: folder.file("logs")),
            details: details)
    }
}
