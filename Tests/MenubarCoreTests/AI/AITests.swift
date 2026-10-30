import Foundation
import Testing

@testable import MenubarCore

/// AI-01 to AI-06: the Claude features. Every input is made up; `claude` is a fake, except in the fixtures, which are
/// real `claude -p` answers to made-up prompts (2026-10-29).
@Suite("Claude")
struct AITests {
    // MARK: - AI-01 The engine, the opt-in and the cap

    @Test("AI-01 the Claude features are off by default and hidden while claude isn't installed")
    @MainActor
    func optIn() async throws {
        let defaults = TemporaryDefaults()
        #expect(AISettings.load(from: defaults.defaults) == AISettings())
        #expect(AISettings().isEnabled == false)
        #expect(AISettings().model == .opus)

        // No claude anywhere: Settings shows nothing, and nothing is offered or run.
        let missing = FakeClaude(answer: try FixtureFiles.data("Claude/digest.json"))
        let hidden = AIStore(defaults: defaults.defaults, runner: missing, resolver: missing.resolver(found: false))
        hidden.update(AISettings(isEnabled: true))
        await hidden.detect()
        #expect(hidden.availability == .missing)
        #expect(!hidden.isSettingsShown)
        #expect(!hidden.isOffered)
        hidden.digestFacts = { Self.someFacts }
        await hidden.writeDigest()
        #expect(await missing.claudeCalls.isEmpty)

        // claude found: Settings shows the section; off, the features stay hidden and nothing is sent.
        let other = TemporaryDefaults()
        let found = FakeClaude(answer: try FixtureFiles.data("Claude/digest.json"))
        let store = AIStore(defaults: other.defaults, runner: found, resolver: found.resolver(found: true))
        store.digestFacts = { Self.someFacts }
        await store.detect()
        #expect(store.isSettingsShown)
        #expect(!store.isOffered)
        await store.writeDigest()
        #expect(await found.claudeCalls.isEmpty)
        #expect(store.state(of: .digest) == .idle)

        // On: offered; the first digest shows what it sends and waits; Send sends it and remembers.
        store.update(AISettings(isEnabled: true))
        #expect(store.isOffered)
        await store.writeDigest()
        guard case .review(let prompt) = store.state(of: .digest) else {
            Issue.record("expected the review, got \(store.state(of: .digest))")
            return
        }
        #expect(prompt.text.contains("group/project!42"))
        #expect(await found.claudeCalls.isEmpty)
        await store.send(.digest)
        #expect(await found.claudeCalls.count == 1)
        #expect(store.settings.confirmedUseCases == [.digest])
        #expect(AISettings.load(from: other.defaults).confirmedUseCases == [.digest])
        guard case .answered(let answer) = store.state(of: .digest) else {
            Issue.record("expected an answer, got \(store.state(of: .digest))")
            return
        }
        #expect(answer.text?.hasPrefix("First: !42") == true)
        // The next digest goes without the review.
        await store.writeDigest()
        #expect(await found.claudeCalls.count == 2)
    }

    @Test("AI-01 runs claude with the facts on stdin and only the app's fixed text on the command line")
    func commandLine() async throws {
        let fake = FakeClaude(answer: try FixtureFiles.data("Claude/explain-build.json"))
        let engine = ClaudeEngine(runner: fake, resolver: fake.resolver(found: true))
        let prompt = ClaudePrompt.explainBuild(Self.failedBuild)
        let run = try await engine.run(prompt, model: .sonnet, budgetUSD: 0.5)
        #expect(run.costUSD > 0)

        let call = try #require(await fake.claudeCalls.first)
        #expect(call.executable == "/opt/homebrew/bin/claude")
        #expect(Array(call.arguments.prefix(11)) == [
            "-p", "--output-format", "json", "--model", "claude-sonnet-5-5", "--tools", "", "--safe-mode",
            "--no-session-persistence", "--max-budget-usd", "0.50",
        ])
        #expect(call.arguments.contains("--json-schema"))
        #expect(call.input == prompt.text)
        // Nothing of the facts is an argument: the log line, the test, the commit message.
        let line = call.arguments.joined(separator: " ")
        for fact in ["expected:<90>", "CartServiceTest", "Apply discount", "MR-42", "BUILD FAILURE"] {
            #expect(!line.contains(fact), "\(fact) is on the command line")
        }
        // The budget is never below a cent, even when less is left.
        #expect(ClaudeEngine.arguments(for: prompt, model: .opus, budgetUSD: 0.001).contains("0.01"))
        // claude is looked for once.
        _ = try await engine.run(prompt, model: .opus, budgetUSD: 1)
        #expect(await fake.shellCalls <= 1)
    }

    @Test("AI-01 parses claude's JSON output: the answer, the structured answer, the tokens, the cost and errors")
    func parsesOutput() throws {
        let explain = try ClaudeRun.parse(FixtureFiles.data("Claude/explain-build.json"))
        #expect(!explain.isError)
        #expect(explain.model == "claude-opus-5-5")
        #expect(explain.usage == ClaudeUsage(inputTokens: 1407, outputTokens: 275))
        #expect(abs(explain.costUSD - 0.016748) < 0.000_001)
        #expect(explain.durationMS == 3562)
        let explanation = try #require(explain.decoded(BuildExplanation.self))
        #expect(explanation.verdict == .real)
        #expect(explanation.cause.contains("appliesDiscount"))

        let summary = try #require(try ClaudeRun.parse(FixtureFiles.data("Claude/summarize-threads.json")).decoded(ThreadsSummary.self))
        #expect(summary.agreed.count == 2)
        #expect(summary.open.map(\.waitingOn) == ["Jane Doe (jdoe)", "Kim Park (kpark)"])

        let digest = try ClaudeRun.parse(FixtureFiles.data("Claude/digest.json"))
        #expect(digest.structured == nil)
        #expect(digest.text?.contains("Review !40") == true)
        #expect(digest.model == "claude-opus-5-5")

        // An error answer: no result, its cost spent all the same, its message.
        let budget = try ClaudeRun.parse(FixtureFiles.data("Claude/budget-error.json"))
        #expect(budget.isError)
        #expect(budget.subtype == "error_max_budget_usd")
        #expect(budget.text == nil)
        #expect(budget.costUSD > 0)
        #expect(budget.errorMessage == "Reached maximum budget ($0.000001)")

        // A structured answer in a code fence, as text only, still reads; a wrong verdict reads as unclear.
        let fenced = ClaudeRun(text: "```json\n{\"cause\":\"c\",\"fix\":\"f\",\"verdict\":\"maybe\"}\n```")
        #expect(fenced.decoded(BuildExplanation.self) == BuildExplanation(cause: "c", fix: "f", verdict: .unclear))
        #expect(throws: (any Error).self) { try ClaudeRun.parse(Data("Invalid API key · Please run /login".utf8)) }
    }

    @Test("AI-01 sums the month's reported costs and stops at the monthly cap")
    @MainActor
    func monthlyCap() async throws {
        // The rule.
        let october = AIUsage(month: "2026-10", costUSD: 9.5)
        #expect(AICostCap.allowance(usage: october, capUSD: 10) == .allowed(budgetUSD: 0.5))
        #expect(AICostCap.allowance(usage: AIUsage(month: "2026-10", costUSD: 2), capUSD: 10) == .allowed(budgetUSD: 1))
        #expect(AICostCap.allowance(usage: AIUsage(month: "2026-10", costUSD: 9.995), capUSD: 10) == .reached(spentUSD: 9.995, capUSD: 10))
        #expect(AICostCap.allowance(usage: AIUsage(month: "2026-10", costUSD: 12), capUSD: 10) == .reached(spentUSD: 12, capUSD: 10))
        // A new month starts at zero.
        #expect(october.current(in: "2026-11") == AIUsage(month: "2026-11"))
        let added = october.adding(costUSD: 0.25, usage: ClaudeUsage(inputTokens: 100, outputTokens: 20), month: "2026-10")
        #expect(added == AIUsage(month: "2026-10", costUSD: 9.75, answers: 1, inputTokens: 100, outputTokens: 20))
        #expect(october.adding(costUSD: 0.25, usage: ClaudeUsage(), month: "2026-11").costUSD == 0.25)

        // The store: each answer's cost is summed, an error answer's too, within what the cap leaves.
        let defaults = TemporaryDefaults()
        let now = Date(timeIntervalSince1970: 1_793_000_000)  // 2026-10
        let month = AIUsage.month(of: now)
        AIUsage(month: month, costUSD: 9.98).save(to: defaults.defaults)
        let fake = FakeClaude(answer: try FixtureFiles.data("Claude/budget-error.json"), status: 1)
        let store = AIStore(
            defaults: defaults.defaults, runner: fake, now: { now }, resolver: fake.resolver(found: true))
        store.update(AISettings(isEnabled: true, monthlyCapUSD: 10, confirmedUseCases: [.digest]))
        store.digestFacts = { Self.someFacts }
        await store.writeDigest()
        #expect(await fake.claudeCalls.count == 1)
        #expect(await fake.claudeCalls.first?.arguments.contains("0.02") == true)
        guard case .failed(let message, _) = store.state(of: .digest) else {
            Issue.record("expected the failure, got \(store.state(of: .digest))")
            return
        }
        #expect(message == "Claude answered with an error: Reached maximum budget ($0.000001)")
        #expect(AIUsage.load(from: defaults.defaults, month: month).answers == 1)
        #expect(AIUsage.load(from: defaults.defaults, month: month).costUSD > 9.98)

        // At the cap: nothing is sent, and the card says why.
        AIUsage(month: month, costUSD: 10).save(to: defaults.defaults)
        let capped = AIStore(
            defaults: defaults.defaults, runner: fake, now: { now }, resolver: fake.resolver(found: true))
        capped.digestFacts = { Self.someFacts }
        await capped.writeDigest()
        #expect(await fake.claudeCalls.count == 1)
        guard case .failed(let reason, _) = capped.state(of: .digest) else {
            Issue.record("expected the cap, got \(capped.state(of: .digest))")
            return
        }
        #expect(reason.hasPrefix("This month's Claude answers reached the $10 cap"))
        // A higher cap lets it through.
        capped.update(AISettings(isEnabled: true, monthlyCapUSD: 20, confirmedUseCases: [.digest]))
        await capped.writeDigest()
        #expect(await fake.claudeCalls.count == 2)
    }

    @Test("AI-01 logs only the use case, the model, the tokens, the cost and the exit code")
    @MainActor
    func logsOnlyCounts() async throws {
        let defaults = TemporaryDefaults()
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url, now: { Date() })
        let fake = FakeClaude(answer: try FixtureFiles.data("Claude/digest.json"))
        let store = AIStore(defaults: defaults.defaults, runner: fake, log: log, resolver: fake.resolver(found: true))
        store.update(AISettings(isEnabled: true, confirmedUseCases: [.digest]))
        store.digestFacts = { Self.someFacts }
        await store.writeDigest()
        try await Task.sleep(for: .milliseconds(200))
        let text = await log.entries().map(\.message).joined(separator: "\n")
        #expect(text.contains("Claude: daily digest, claude-opus-5-5, 942 tokens in, 394 out, $0.015, exit 0"))
        for secretive in ["Add cart discount", "Review !40", "group/project!42", "Speed up search"] {
            #expect(!text.contains(secretive), "\(secretive) is in the log")
        }
    }

    // MARK: - AI-06 Redaction

    @Test(
        "AI-06 redacts tokens, cookies, keys and passwords from everything sent",
        arguments: [
            ("Authorization: Bearer glpat-abcdefghij0123456789", "Authorization: Bearer [redacted]"),
            ("curl -H \"Authorization: Basic amRvZTpzZWNyZXQ=\" https://ci.example.com", "curl -H \"Authorization: Basic [redacted]\" https://ci.example.com"),
            ("Cookie: JSESSIONID=abc123; remember=xyz", "Cookie: [redacted]"),
            ("Set-Cookie: session=deadbeef; Path=/", "Set-Cookie: [redacted]"),
            ("git clone https://jdoe:hunter22@git.example.com/group/project.git", "git clone https://jdoe:[redacted]@git.example.com/group/project.git"),
            ("password=hunter22 user=jdoe", "password=[redacted] user=jdoe"),
            ("\"api_key\": \"0123456789abcdef\"", "\"api_key\": \"[redacted]\""),
            ("GITLAB_TOKEN: glpat-xyz", "GITLAB_TOKEN: [redacted]"),
            ("export CLIENT_SECRET=s3cr3tvalue", "export CLIENT_SECRET=[redacted]"),
            ("mvn deploy --password hunter22 -B", "mvn deploy --password [redacted] -B"),
            ("token ghp_abcdefghijklmnopqrstuvwxyz0123456789 leaked", "token [redacted] leaked"),
            ("key sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "key [redacted]"),
            ("aws AKIAABCDEFGHIJKLMNOP done", "aws [redacted] done"),
            ("slack xoxb-1234567890-abcdefghij", "slack [redacted]"),
            ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N", "jwt [redacted]"),
            ("jenkins 11aabbccddeeff00112233445566778899 api", "jenkins [redacted] api"),
            ("-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----\nafter", "[redacted private key]\nafter"),
        ])
    func redacts(_ input: String, _ expected: String) {
        #expect(SecretRedactor().redact(input) == expected)
    }

    @Test("AI-06 removes the app's own tokens and keeps the facts Claude needs")
    func redactsKnownTokensKeepsFacts() throws {
        // The Jenkins token is stored as base64 of user:api-token; the API token alone is removed too.
        let jenkins = Data("jdoe:my-jenkins-api-token-value".utf8).base64EncodedString()
        let redactor = SecretRedactor(knownSecrets: [jenkins, "gitlab-secret-value-123", "short"])
        let text = """
            Basic \(jenkins) and my-jenkins-api-token-value
            and gitlab-secret-value-123, short stays
            """
        let redacted = redactor.redact(text)
        #expect(!redacted.contains("my-jenkins-api-token-value"))
        #expect(!redacted.contains(jenkins))
        #expect(!redacted.contains("gitlab-secret-value-123"))
        #expect(redacted.contains("short stays"))

        // What explains a failure stays: commit hashes, authors, test names, assertion messages, log lines.
        let facts = """
            - 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b #7 Jane Doe: Apply discount after tax
            Merge request: group/project!42 "Add cart discount" by Jane Doe (jdoe)
            com.example.auth.PasswordValidatorTest.rejectsShort: expected:<false> but was:<true>
            [ERROR] TokenRefreshIT.refreshesExpiredToken:88 Connection refused
            Tests run: 120, Failures: 1, Errors: 0, Skipped: 0
            Should the access token be refreshed before the call?
            """
        #expect(SecretRedactor().redact(facts) == facts)
    }

    // MARK: - AI-02 Explain a failed build

    @Test("AI-02 the failed build's prompt has its stages, tests, the changes since the last green build and the log's end")
    func explainBuildPrompt() {
        let prompt = ClaudePrompt.explainBuild(Self.failedBuild)
        #expect(prompt.useCase == .explainBuild)
        #expect(prompt.schema?.contains("\"verdict\"") == true)
        let text = prompt.text
        #expect(text.contains("Build: MR-42 #7 \"Add cart discount\", result FAILURE"))
        #expect(text.contains("Failed stages: Unit tests"))
        #expect(text.contains("Tests: 1 of 120 failed"))
        #expect(text.contains("- com.example.cart.CartServiceTest.appliesDiscount (regression: passed in the build before): expected:<90> but was:<100>"))
        #expect(text.contains("Changes since the last green build (#5), newest first:"))
        #expect(text.contains("- 1a2b3c4d5e #7 Jane Doe: Apply discount after tax"))
        #expect(text.hasSuffix("[INFO] BUILD FAILURE"))

        // A long log keeps its end, from a line's start; long lists are cut with a count.
        var long = Self.failedBuild
        long.logTail = (1...5000).map { "line \($0) of the build" }.joined(separator: "\n")
        long.failedTests = (1...40).map { FailedTest(className: "a.B", name: "t\($0)", status: .failed) }
        long.changes = []
        long.lastGreen = nil
        let cut = ClaudePrompt.explainBuild(long).text
        #expect(cut.contains("[… earlier lines left out …]\nline "))
        #expect(cut.hasSuffix("line 5000 of the build"))
        #expect(!cut.contains("line 1 of the build"))
        #expect(cut.contains("- and 15 more"))
        #expect(cut.contains("Changes: none known (no green build in the job's recent history)"))
        #expect(cut.count < BuildFailureFacts.logCharacters + 3000)
    }

    @Test("AI-02 reads the end of the console log and the changes since the last green build from Jenkins")
    func readsFailureFromJenkins() async throws {
        let stub = StubTransport()
        let log = (1...20000).map { "step \($0)" }.joined(separator: "\n") + "\n[INFO] BUILD FAILURE\n"
        stub.answer(path: "/job/project/job/MR-42/7/consoleText", body: log)
        stub.answer(path: "/job/project/job/MR-42/api/json", body: """
            {"lastSuccessfulBuild": {"number": 5},
             "builds": [
               {"number": 8, "changeSets": [{"items": [{"commitId": "c8", "msg": "Later", "author": {"fullName": "Kim Park"}}]}]},
               {"number": 7, "changeSets": [{"items": [
                  {"commitId": "c71", "msg": "First of seven", "author": {"fullName": "Jane Doe"}},
                  {"commitId": "c72", "msg": "Second of seven\\n\\nwith a body", "author": {"fullName": "Jane Doe"}}]}]},
               {"number": 6, "changeSets": [], "changeSet": {"items": [{"commitId": "c6", "msg": "Six", "author": null}]}},
               {"number": 5, "changeSets": [{"items": [{"commitId": "c5", "msg": "Green", "author": {"fullName": "Sam Lee"}}]}]}
             ]}
            """)
        let client = JenkinsClient(
            jobURL: URL(string: "https://ci.example.com/job/project/")!, token: "dG9rZW4=", transport: stub)

        let tail = try await client.consoleTail(job: "MR-42", number: 7)
        #expect(tail.hasSuffix("[INFO] BUILD FAILURE\n"))
        #expect(tail.utf8.count <= JenkinsClient.consoleTailBytes)
        #expect(tail.hasPrefix("step "))

        let (changes, green) = try await client.changesSinceLastGreen(job: "MR-42", number: 7)
        #expect(green == 5)
        #expect(changes.map(\.commit) == ["c72", "c71", "c6"])
        #expect(changes.map(\.message) == ["Second of seven", "First of seven", "Six"])
        #expect(changes.last?.author == "Someone")
        let request = try #require(stub.requests(path: "/job/project/job/MR-42/api/json").first)
        #expect(request.url.query?.contains("lastSuccessfulBuild%5Bnumber%5D") == true)
        #expect(request.headers["Authorization"] == "Basic dG9rZW4=")
    }

    // MARK: - AI-03 Summarize a discussion

    @Test("AI-03 the discussion prompt lists the unresolved threads first, every note, cut when long")
    func threadsPrompt() throws {
        let sam = MergeRequest.Person(username: "slee", name: "Sam Lee")
        let jane = MergeRequest.Person(username: "jdoe", name: "Jane Doe")
        let facts = ThreadsFacts(
            reference: "group/project!42", title: "Add cart discount", author: jane,
            threads: [
                DiscussionThread(resolved: true, notes: [.init(author: sam, body: "Typo in the changelog."), .init(author: jane, body: "Fixed.")]),
                DiscussionThread(
                    resolved: false, location: "src/CartService.swift:42",
                    notes: [.init(author: sam, body: "Shouldn't the discount apply before tax?\nThe spec says so."),
                            .init(author: nil, body: String(repeating: "x", count: 3000))]),
            ])
        let text = ClaudePrompt.summarizeThreads(facts).text
        #expect(text.contains("Merge request: group/project!42 \"Add cart discount\" by Jane Doe (jdoe)"))
        let unresolved = try #require(text.range(of: "Thread 1 (unresolved) on src/CartService.swift:42"))
        let resolved = try #require(text.range(of: "Thread 2 (resolved)"))
        #expect(unresolved.lowerBound < resolved.lowerBound)
        #expect(text.contains("- Sam Lee (slee): Shouldn't the discount apply before tax?\n  The spec says so."))
        #expect(text.contains("- Someone: " + String(repeating: "x", count: ThreadsFacts.noteCharacters) + "…"))
        #expect(!text.contains(String(repeating: "x", count: ThreadsFacts.noteCharacters + 1)))

        // Too much text: the rest is left out with a count.
        let many = ThreadsFacts(
            reference: "group/project!1", title: "Big", author: jane,
            threads: (1...100).map { _ in DiscussionThread(resolved: false, notes: [.init(author: sam, body: String(repeating: "y", count: 1400))]) })
        let cut = ClaudePrompt.summarizeThreads(many).text
        #expect(cut.count <= ThreadsFacts.totalCharacters + 100)
        #expect(cut.contains("more threads left out for length"))
    }

    @Test("AI-03 reads every note of the resolvable threads, without system notes")
    func readsThreadText() throws {
        let operation = try #require(GitLabOperation.threadText(of: DescriptionSource(
            kind: .mergeRequest, reference: "group/project!42",
            webURL: URL(string: "https://gitlab.example.com/group/project/-/merge_requests/42")!, updatedAt: Date())))
        #expect(operation.variables == #"{"path":"group/project","iid":"42"}"#)
        let answer = """
            {"data": {"project": {"mergeRequest": {"discussions": {"nodes": [
              {"resolvable": true, "resolved": false, "notes": {"nodes": [
                {"body": "Before tax?", "system": false, "author": {"username": "slee", "name": "Sam Lee"},
                 "position": {"filePath": "src/Cart.swift", "newLine": 42}},
                {"body": "added 1 commit", "system": true, "author": {"username": "jdoe", "name": "Jane Doe"}},
                {"body": "Switched.", "system": false, "author": {"username": "jdoe", "name": "Jane Doe"}}]}},
              {"resolvable": false, "resolved": false, "notes": {"nodes": [{"body": "Nice!", "system": false}]}},
              {"resolvable": true, "resolved": true, "notes": {"nodes": [{"body": "Typo", "system": false, "author": null}]}}
            ]}}}}}
            """
        let threads = try operation.decode(Data(answer.utf8))
        #expect(threads.count == 2)
        #expect(threads[0].location == "src/Cart.swift:42")
        #expect(threads[0].notes.map(\.body) == ["Before tax?", "Switched."])
        #expect(threads[0].resolved == false)
        #expect(threads[1].resolved == true)
        #expect(threads[1].notes.first?.author == nil)
    }

    // MARK: - AI-04 The digest

    @Test("AI-04 the digest is written from the app's own stores: my merge requests, reviews, red builds, items by slot")
    func digestFacts() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let gitLab = "https://gitlab.example.com/group/project"
        func mergeRequest(_ iid: Int, _ title: String, roles: Set<MergeRequest.Role>, author: String = "jdoe") -> MergeRequest {
            MergeRequest(
                iid: iid, title: title, webURL: URL(string: "\(gitLab)/-/merge_requests/\(iid)")!,
                reference: "group/project!\(iid)", author: MergeRequest.Person(username: author, name: author == "jdoe" ? "Jane Doe" : "Sam Lee"),
                updatedAt: now.addingTimeInterval(-3 * 3600), roles: roles)
        }
        let sections = MergeRequestSections(
            [mergeRequest(42, "Add cart discount", roles: [.authored]),
             mergeRequest(40, "Fix rounding", roles: [.reviewRequested], author: "slee")],
            me: "jdoe")
        let red = Build(
            job: "MR-42", number: 7, title: "Add cart discount", kind: .mine,
            phase: .finished(result: .failure, duration: 600), startedAt: now.addingTimeInterval(-3600))
        let green = Build(job: "MR-45", number: 2, kind: .mine, phase: .finished(result: .success, duration: 60), startedAt: now)
        func item(_ number: Int, _ title: String, labels: [String]) -> WorkItem {
            WorkItem(
                reference: "group/project#\(number)", title: title, webURL: URL(string: "\(gitLab)/-/issues/\(number)")!,
                labels: labels.map { Label(title: $0, color: "#fff") }, updatedAt: now)
        }
        let facts = DigestFacts.gather(
            mergeRequests: sections, builds: [green, red],
            workItems: [item(1301, "Login page", labels: []), item(1234, "Cart discount", labels: ["slot::2026.45"]),
                        item(1240, "Search speed", labels: ["slot::2026.44"])],
            slotPrefix: "slot::", now: now)
        #expect(facts.myMergeRequests == ["group/project!42 \"Add cart discount\", updated 3 h ago"])
        #expect(facts.reviews == ["group/project!40 \"Fix rounding\", updated 3 h ago, by Sam Lee"])
        #expect(facts.redBuilds == ["!42 #7 \"Add cart discount\", FAILURE"])
        #expect(facts.workItemsBySlot.map(\.name) == ["2026.44", "2026.45", nil])
        #expect(facts.workItemsBySlot.last?.items == ["group/project#1301 \"Login page\" (issue)"])

        let text = ClaudePrompt.digest(facts).text
        #expect(text.contains("My merge requests (1):\n- group/project!42"))
        #expect(text.contains("Red builds (1):\n- !42 #7"))
        #expect(text.contains("- no slot: group/project#1301"))
        #expect(ClaudePrompt.digest(facts).schema == nil)
        #expect(DigestFacts().isEmpty)
    }

    @Test("AI-04 the morning digest comes at the time the user set, today or tomorrow")
    func morningDigestTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Zurich"))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 7, minute: 30)))
        let nine = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 9)))
        let tomorrow = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9)))
        #expect(AIStore.nextDigest(after: morning, minutes: 9 * 60, calendar: calendar) == nine)
        #expect(AIStore.nextDigest(after: nine, minutes: 9 * 60, calendar: calendar) == tomorrow)
        #expect(AISettings().morningDigest == false)
    }

    // MARK: - AI-05 Open in Claude Code

    @Test("AI-05 Open in Claude Code starts in the checkout on the item's branch, else asks which")
    func picksCheckout() {
        let one = Checkout(path: "/work/develop1/project", name: "develop1", baseBranch: "develop", folder: UUID())
        let two = Checkout(path: "/work/develop2/project", name: "develop2", baseBranch: "develop", folder: UUID())
        let readings: [Checkout.ID: CheckoutReading] = [
            one.id: .read(CheckoutState(status: GitStatus(branch: "develop"))),
            two.id: .read(CheckoutState(status: GitStatus(branch: "1234-cart-discount"))),
        ]
        let gitLab = "https://gitlab.example.com/group/project"
        let mergeRequest = MergeRequest(
            iid: 42, title: "Add cart discount", webURL: URL(string: "\(gitLab)/-/merge_requests/42")!,
            reference: "group/project!42", author: MergeRequest.Person(username: "jdoe", name: "Jane Doe"),
            updatedAt: Date(), roles: [.authored], sourceBranch: "1234-cart-discount")
        let item = WorkItem(
            reference: "group/project#1234", title: "Cart discount", webURL: URL(string: "\(gitLab)/-/issues/1234")!, updatedAt: Date())
        let other = WorkItem(
            reference: "group/project#99", title: "Elsewhere", webURL: URL(string: "\(gitLab)/-/issues/99")!, updatedAt: Date())
        let build = Build(job: "MR-42", number: 7, kind: .mine, phase: .finished(result: .failure, duration: 1), startedAt: Date())
        let checkouts = [one, two]
        func match(_ context: ClaudeCodeContext) -> String? {
            context.checkout(in: checkouts, readings: readings, mergeRequests: [mergeRequest])?.name
        }
        #expect(match(.mergeRequest(mergeRequest)) == "develop2")
        #expect(match(.workItem(item)) == "develop2")
        #expect(match(.build(build, page: nil, failedTests: [])) == "develop2")
        #expect(match(.workspace(one, task: WorkspaceTask())) == "develop1")
        // No checkout on the branch: the user picks one.
        #expect(match(.workItem(other)) == nil)

        // The prompt names the item and its link, and never starts like an option.
        let prompt = ClaudeCodeContext.build(
            build, page: URL(string: "https://ci.example.com/job/project/job/MR-42/7/"),
            failedTests: [FailedTest(className: "a.CartTest", name: "applies", status: .failed, message: "expected:<90>\nmore")]
        ).prompt(in: two)
        #expect(prompt.hasPrefix("Context from menubar-monitor, for this checkout (develop2, base branch origin/develop):"))
        #expect(prompt.contains("- Build: https://ci.example.com/job/project/job/MR-42/7/"))
        #expect(prompt.contains("- Failed test: a.CartTest.applies: expected:<90>\n"))
        #expect(ClaudeCodeContext.workItem(item).prompt(in: two).contains("- Link: \(gitLab)/-/issues/1234"))
    }

    @Test("AI-05 the launch script is fixed text: the path and the prompt reach claude as one argument, never as code")
    func launchScriptNeverRunsText() async throws {
        let folder = try TemporaryFolder()
        // A checkout and a prompt full of shell syntax, and a fake claude that records its arguments.
        let checkout = folder.url.appending(path: "my work $(touch pwned-dir)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let record = folder.url.appending(path: "arguments.txt", directoryHint: .notDirectory)
        let fakeClaude = folder.url.appending(path: "claude", directoryHint: .notDirectory)
        try """
            #!/bin/zsh -f
            print -rn -- "$#|$PWD|$1" > '\(record.path(percentEncoded: false))'
            """.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeClaude.path(percentEncoded: false))
        let prompt = "Context: \"quoted\" $(touch pwned) `touch pwned2` ; rm -rf ~ && echo $HOME\nsecond line"

        let launches = folder.url.appending(path: "launches", directoryHint: .isDirectory)
        let script = try ClaudeCodeLaunch.write(
            prompt: prompt, directory: checkout.path(percentEncoded: false), claude: fakeClaude, in: launches)
        #expect(try String(contentsOf: script, encoding: .utf8) == ClaudeCodeLaunch.script)
        #expect(!ClaudeCodeLaunch.script.contains("touch"))
        let mode = try FileManager.default.attributesOfItem(atPath: script.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o700)

        // Run it as Terminal would.
        let output = try await SystemProcessRunner().run(URL(filePath: "/bin/zsh"), arguments: [script.path(percentEncoded: false)], input: nil)
        #expect(output.status == 0)
        let recorded = try String(contentsOf: record, encoding: .utf8)
        let parts = recorded.split(separator: "|", maxSplits: 2).map(String.init)
        #expect(parts.first == "1")
        #expect(parts.dropFirst().first.map { URL(filePath: $0).resolvingSymlinksInPath().path } == checkout.resolvingSymlinksInPath().path)
        #expect(parts.last == prompt)
        // Nothing in the text ran, and the launch folder is gone.
        for name in ["pwned", "pwned2", "pwned-dir"] {
            #expect(!FileManager.default.fileExists(atPath: checkout.appending(path: name).path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: name).path(percentEncoded: false)))
        }
        #expect(!FileManager.default.fileExists(atPath: script.deletingLastPathComponent().path(percentEncoded: false)))
    }

    @Test("AI-05 Open in Claude Code opens Terminal with the script, the prompt redacted, and logs no text")
    @MainActor
    func opensTerminal() async throws {
        let defaults = TemporaryDefaults()
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url, now: { Date() })
        let fake = FakeClaude(answer: Data())
        let launcher = RecordingLauncher()
        let store = AIStore(
            defaults: defaults.defaults, runner: fake, launcher: launcher,
            terminals: FakeTerminals(apps: [FakeTerminals.terminal], handler: "com.apple.Terminal"),
            launchFolder: folder.url.appending(path: "launches", directoryHint: .isDirectory), log: log,
            resolver: fake.resolver(found: true))
        let checkout = Checkout(path: "/work/develop2/project", name: "develop2", baseBranch: "develop", folder: UUID())
        let item = WorkItem(
            reference: "group/project#1234", title: "Rotate password=hunter22 in CI",
            webURL: URL(string: "https://gitlab.example.com/group/project/-/issues/1234")!, updatedAt: Date())

        // Off: nothing opens.
        await store.openInClaudeCode(.workItem(item), in: checkout)
        #expect(await launcher.calls.isEmpty)

        store.update(AISettings(isEnabled: true))
        await store.openInClaudeCode(.workItem(item), in: checkout)
        let call = try #require(await launcher.calls.first)
        #expect(call.program == "/usr/bin/open")
        #expect(call.arguments.count == 3)
        #expect(Array(call.arguments.prefix(2)) == ["-a", "/System/Applications/Utilities/Terminal.app"])
        #expect(call.arguments[2].hasSuffix("/" + ClaudeCodeLaunch.scriptName))
        let promptFile = URL(filePath: call.arguments[2]).deletingLastPathComponent().appending(path: "prompt")
        let sent = try String(contentsOf: promptFile, encoding: .utf8)
        #expect(sent.contains("group/project#1234"))
        #expect(!sent.contains("hunter22"))
        #expect(store.lastLaunch?.message == "Claude Code starts in develop2, in Terminal")

        try await Task.sleep(for: .milliseconds(200))
        let text = await log.entries().map(\.message).joined(separator: "\n")
        #expect(text.contains("Claude: open in Claude Code in develop2, exit 0"))
        #expect(!text.contains("Rotate"))
    }

    @Test("AI-05 Open in Claude Code opens the script with the user's terminal, and Terminal with the reason when it can't run one")
    @MainActor
    func opensTheUsersTerminal() async throws {
        let defaults = TemporaryDefaults()
        let folder = try TemporaryFolder()
        let fake = FakeClaude(answer: Data())
        let launcher = RecordingLauncher()
        let terminals = FakeTerminals(
            apps: [FakeTerminals.terminal, FakeTerminals.cmux, FakeTerminals.foldersOnly], handler: "com.cmuxterm.app")
        let store = AIStore(
            defaults: defaults.defaults, runner: fake, launcher: launcher, terminals: terminals,
            launchFolder: folder.url.appending(path: "launches", directoryHint: .isDirectory),
            resolver: fake.resolver(found: true))
        store.update(AISettings(isEnabled: true))
        let checkout = Checkout(path: "/work/develop2/project", name: "develop2", baseBranch: "develop", folder: UUID())
        let item = WorkItem(
            reference: "group/project#1234", title: "Fix login",
            webURL: URL(string: "https://gitlab.example.com/group/project/-/issues/1234")!, updatedAt: Date())

        // Default is the app that opens .command files: cmux here, with the script as the one other argument.
        await store.openInClaudeCode(.workItem(item), in: checkout)
        let first = try #require(await launcher.calls.last)
        #expect(Array(first.arguments.prefix(2)) == ["-a", "/Applications/cmux.app"])
        #expect(first.arguments.count == 3 && first.arguments[2].hasSuffix("/" + ClaudeCodeLaunch.scriptName))
        #expect(store.lastLaunch?.message == "Claude Code starts in develop2, in cmux")

        // A terminal that can't run a script: Terminal, and the result says so.
        TerminalChoice.setPreferred("dev.example.folders", in: defaults.defaults)
        await store.openInClaudeCode(.workItem(item), in: checkout)
        let second = try #require(await launcher.calls.last)
        #expect(Array(second.arguments.prefix(2)) == ["-a", "/System/Applications/Utilities/Terminal.app"])
        #expect(store.lastLaunch?.message == "Claude Code starts in develop2, in Terminal (Folders can't run a script)")
        #expect(store.lastLaunch?.isProblem == false)
    }

    // MARK: - Made-up values

    static let failedBuild = BuildFailureFacts(
        title: "Add cart discount", job: "MR-42", number: 7, result: "FAILURE", failedStages: ["Unit tests"],
        testCounts: TestCounts(failed: 1, total: 120),
        failedTests: [FailedTest(
            className: "com.example.cart.CartServiceTest", name: "appliesDiscount", status: .regression,
            message: "expected:<90> but was:<100>")],
        changes: [BuildChange(commit: "1a2b3c4d5e6f", author: "Jane Doe", message: "Apply discount after tax", build: 7)],
        lastGreen: 5,
        logTail: "[ERROR] Tests run: 120, Failures: 1\n[ERROR] CartServiceTest.appliesDiscount:42 expected:<90> but was:<100>\n[INFO] BUILD FAILURE\n")

    static let someFacts = DigestFacts(
        myMergeRequests: ["group/project!42 \"Add cart discount\", pipeline failed"],
        reviews: ["group/project!40 \"Fix rounding\", by Sam Lee"])
}

/// A `claude` that answers every run with the same output, and a login shell that knows no `PATH`.
private actor FakeClaude: ProcessRunner {
    struct Call: Sendable {
        var executable: String
        var arguments: [String]
        var input: String?
    }

    private let answer: Data
    private let status: Int32
    private(set) var claudeCalls: [Call] = []
    private(set) var shellCalls = 0

    init(answer: Data, status: Int32 = 0) {
        self.answer = answer
        self.status = status
    }

    func run(_ executable: URL, arguments: [String], input: Data?) async throws -> ProcessOutput {
        if executable.lastPathComponent == "zsh" {
            shellCalls += 1
            return ProcessOutput(status: 1)
        }
        claudeCalls.append(Call(
            executable: executable.path(percentEncoded: false), arguments: arguments,
            input: input.map { String(decoding: $0, as: UTF8.self) }))
        return ProcessOutput(status: status, standardOutput: answer)
    }

    /// A resolver that finds `claude` in `/opt/homebrew/bin`, or nowhere.
    nonisolated func resolver(found: Bool) -> ProgramResolver {
        ProgramResolver(runner: self, home: URL(filePath: "/Users/nobody")) { path in
            found && path == "/opt/homebrew/bin/claude"
        }
    }
}

/// A launcher that records what it would start.
private actor RecordingLauncher: ProgramLauncher {
    struct Call: Sendable {
        var program: String
        var arguments: [String]
    }

    private(set) var calls: [Call] = []

    func launch(
        _ program: URL, arguments: [String], directory: URL?, path: [String]?, wait: Duration
    ) async throws -> LaunchOutcome {
        calls.append(Call(program: program.path(percentEncoded: false), arguments: arguments))
        return .exited(status: 0, lastLine: nil)
    }
}
