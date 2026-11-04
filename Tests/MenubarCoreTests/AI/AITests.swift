import Foundation
import Testing

@testable import MenubarCore

/// AI-01 to AI-06: the Claude features. Every input is made up; `claude` is a fake, except in the fixtures, which are
/// real `claude -p` answers to made-up prompts (2026-10-29).
@Suite("Claude")
struct AITests {
    // MARK: - AI-01 The engine and the opt-in

    @Test("AI-01 the Claude features are on by default with Sonnet and the morning digest, hidden while claude isn't installed")
    @MainActor
    func optIn() async throws {
        let defaults = TemporaryDefaults()
        #expect(AISettings.load(from: defaults.defaults) == AISettings())
        let fresh = AISettings()
        #expect(fresh.isEnabled && fresh.morningDigest && fresh.digestMinutes == 8 * 60)
        #expect(fresh.model == .sonnet && fresh.confirmedUseCases.isEmpty)

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

        // claude found: Settings shows the section; with nothing saved the features are offered at once.
        let fresh2 = TemporaryDefaults()
        let offeredFake = FakeClaude(answer: try FixtureFiles.data("Claude/digest.json"))
        let offered = AIStore(defaults: fresh2.defaults, runner: offeredFake, resolver: offeredFake.resolver(found: true))
        await offered.detect()
        #expect(offered.isOffered)

        // Off, the features stay hidden and nothing is sent.
        let other = TemporaryDefaults()
        let found = FakeClaude(answer: try FixtureFiles.data("Claude/digest.json"))
        let store = AIStore(defaults: other.defaults, runner: found, resolver: found.resolver(found: true))
        store.update(AISettings(isEnabled: false))
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
        _ = try await engine.run(prompt, model: .sonnet)

        let call = try #require(await fake.claudeCalls.first)
        #expect(call.executable == "/opt/homebrew/bin/claude")
        #expect(Array(call.arguments.prefix(11)) == [
            "-p", "--output-format", "json", "--model", "sonnet", "--tools", "", "--safe-mode",
            "--no-session-persistence", "--max-budget-usd", "1.00",
        ])
        #expect(call.arguments.contains("--json-schema"))
        #expect(call.input == prompt.text)
        // Nothing of the facts is an argument: the log line, the test, the commit message.
        let line = call.arguments.joined(separator: " ")
        for fact in ["expected:<90>", "CartServiceTest", "Apply discount", "MR-42", "BUILD FAILURE"] {
            #expect(!line.contains(fact), "\(fact) is on the command line")
        }
        // The safety limit is one fixed value, once.
        #expect(ClaudeEngine.arguments(for: prompt, model: .opus).filter { $0 == "--max-budget-usd" }.count == 1)
        // A question about code, which reads files and may review a long diff, gets the higher limit.
        let code = ClaudeEngine.arguments(for: ClaudePrompt(useCase: .askAboutCode, instructions: "i", text: "t"), model: .opus)
        #expect(code.drop { $0 != "--max-budget-usd" }.dropFirst().first == "5.00")
        // claude is looked for once.
        _ = try await engine.run(prompt, model: .opus)
        #expect(await fake.shellCalls <= 1)
    }

    @Test("AI-01 parses claude's JSON output: the answer, the structured answer, the tokens and errors")
    func parsesOutput() throws {
        let explain = try ClaudeRun.parse(FixtureFiles.data("Claude/explain-build.json"))
        #expect(!explain.isError)
        #expect(explain.model == "claude-opus-5-5")
        #expect(explain.usage == ClaudeUsage(inputTokens: 1407, outputTokens: 275))
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

        // An error answer: no result, its message.
        let budget = try ClaudeRun.parse(FixtureFiles.data("Claude/budget-error.json"))
        #expect(budget.isError)
        #expect(budget.subtype == "error_max_budget_usd")
        #expect(budget.text == nil)
        #expect(budget.errorMessage == "Claude stopped before it finished. Ask again.")

        // A structured answer in a code fence, as text only, still reads; a wrong verdict reads as unclear.
        let fenced = ClaudeRun(text: "```json\n{\"cause\":\"c\",\"fix\":\"f\",\"verdict\":\"maybe\"}\n```")
        #expect(fenced.decoded(BuildExplanation.self) == BuildExplanation(verdict: .unclear, cause: "c", nextStep: "f"))
        #expect(throws: (any Error).self) { try ClaudeRun.parse(Data("Invalid API key · Please run /login".utf8)) }
    }

    @Test("AI-01 an answer stopped by the safety limit reads as a plain failure, and the spend of earlier versions is dropped")
    @MainActor
    func stoppedAnswer() async throws {
        let defaults = TemporaryDefaults()
        // What an earlier version stored: the monthly cap in the settings and the month's spend.
        defaults.defaults.set(Data(#"{"isEnabled":true,"monthlyCapUSD":5,"confirmedUseCases":["digest"]}"#.utf8), forKey: AISettings.defaultsKey)
        defaults.defaults.set(Data(#"{"month":"2026-10","costUSD":99}"#.utf8), forKey: "ai.usage")
        let fake = FakeClaude(answer: try FixtureFiles.data("Claude/budget-error.json"), status: 1)
        let store = AIStore(defaults: defaults.defaults, runner: fake, resolver: fake.resolver(found: true))
        #expect(defaults.defaults.data(forKey: "ai.usage") == nil)
        #expect(store.settings.isEnabled)
        store.digestFacts = { Self.someFacts }
        await store.writeDigest()
        // Nothing stops a call before it is sent; the call carries the fixed limit.
        #expect(await fake.claudeCalls.first?.arguments.contains(ClaudeEngine.maxBudgetUSD) == true)
        guard case .failed(let message, _) = store.state(of: .digest) else {
            Issue.record("expected the failure, got \(store.state(of: .digest))")
            return
        }
        #expect(message == "Claude stopped before it finished. Ask again.")
        #expect(!message.contains("$") && !message.localizedCaseInsensitiveContains("budget"))
    }

    @Test("AI-01 logs only the use case, the model, the tokens and the exit code")
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
        #expect(text.contains("Claude: daily digest, claude-opus-5-5, 942 tokens in, 394 out, exit 0"))
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
            ("git clone https://jdoe:hunter22@git.example.com/group/project.git", "git clone https://jdoe:[redacted]@git.example.com/group/project.git"),
            ("password=hunter22 user=jdoe", "password=[redacted] user=jdoe"),
            ("\"api_key\": \"0123456789abcdef\"", "\"api_key\": \"[redacted]\""),
            ("GITLAB_TOKEN: glpat-xyz", "GITLAB_TOKEN: [redacted]"),
            ("mvn deploy --password hunter22 -B", "mvn deploy --password [redacted] -B"),
            ("token ghp_abcdefghijklmnopqrstuvwxyz0123456789 leaked", "token [redacted] leaked"),
            ("key sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "key [redacted]"),
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

    // MARK: - AI-02 Explain a failed build: in WhyDidItFailTests

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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Zurich"))
        // Tuesday 3 November 2026: 2026.49 freezes on Friday, 2026.44 released on 26 October.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 8)))
        let gitLab = "https://gitlab.example.com/group/project"
        func mergeRequest(
            _ iid: Int, _ title: String, roles: Set<MergeRequest.Role>, author: String = "jdoe", draft: Bool = false,
            status: MergeRequest.MergeStatus? = nil, reviewers: [MergeRequest.Reviewer] = []
        ) -> MergeRequest {
            MergeRequest(
                iid: iid, title: title, webURL: URL(string: "\(gitLab)/-/merge_requests/\(iid)")!,
                reference: "group/project!\(iid)", isDraft: draft, mergeStatus: status,
                author: MergeRequest.Person(username: author, name: author == "jdoe" ? "Jane Doe" : "Sam Lee"),
                reviewers: reviewers, updatedAt: now.addingTimeInterval(-3 * 3600), roles: roles)
        }
        let reviewers = [
            MergeRequest.Reviewer(username: "slee", name: "Sam Lee", reviewState: .approved, approved: true),
            MergeRequest.Reviewer(username: "kpark", name: "Kim Park", reviewState: .unreviewed, approved: false),
        ]
        let sections = MergeRequestSections(
            [mergeRequest(42, "Add cart discount", roles: [.authored], status: .mergeable, reviewers: reviewers),
             mergeRequest(41, "Try new layout", roles: [.authored], draft: true),
             mergeRequest(40, "Fix rounding", roles: [.reviewRequested], author: "slee"),
             mergeRequest(39, "Spike search", roles: [.reviewRequested], author: "slee", draft: true)],
            me: "jdoe")
        func build(_ job: String, _ number: Int, _ result: BuildResult, kind: JobKind = .mine, hoursAgo: Double) -> Build {
            Build(
                job: job, number: number, title: job == "MR-42" ? "Add cart discount" : nil, kind: kind,
                phase: .finished(result: result, duration: 600), startedAt: now.addingTimeInterval(-hoursAgo * 3600))
        }
        let red = build("MR-42", 7, .failure, hoursAgo: 1)
        let builds = [
            build("MR-42", 6, .failure, hoursAgo: 5), red, build("MR-45", 2, .success, hoursAgo: 0.5),
            build("develop", 3, .unstable, kind: .watched, hoursAgo: 2),
        ]
        func item(_ number: Int, _ title: String, labels: [String] = [], state: WorkItemState = .opened,
                  blocked: Bool? = nil, due: String? = nil) -> WorkItem {
            WorkItem(
                reference: "group/project#\(number)", title: title, webURL: URL(string: "\(gitLab)/-/issues/\(number)")!,
                state: state, labels: labels.map { Label(title: $0, color: "#fff") }, updatedAt: now, isBlocked: blocked,
                dueDate: due)
        }
        let jobURL = URL(string: "https://jenkins.example.com/job/project")!
        let facts = DigestFacts.gather(
            mergeRequests: sections, builds: builds,
            workItems: [item(1234, "Cart discount", labels: ["slot::2026.44"], blocked: true),
                        item(1240, "Search speed", labels: ["slot::2026.49"]),
                        item(1301, "Login page", due: "2026-11-04"),
                        item(1100, "Old bug", labels: ["slot::2026.49"], state: .closed)],
            slotPrefix: "slot::", jobURL: { _ in jobURL }, now: now, calendar: calendar)

        #expect(facts.items.map(\.kind) == [
            .mergeRequest, .mergeRequest, .review, .review, .build, .build, .workItem, .workItem, .workItem, .slot, .slot,
        ])
        #expect(facts.items.map(\.shortRef) == [
            "!42", "!41", "!40", "!39", "!42 #7", "develop #3", "#1234", "#1240", "#1301", "2026.44", "2026.49",
        ])
        #expect(facts.items.map(\.state.text) == [
            "Ready to merge", "Draft", "Waiting on you", "Draft", "Failed", "Unstable", "Blocked", "Open", "Due tomorrow",
            "Released 8 days ago", "Code freeze in 3 days",
        ])
        // The app's own rules: what to merge, a review that isn't a draft, my red build, a blocked or due item, a slot
        // released with my items open or near its freeze.
        #expect(facts.items.map(\.needsYou) == [true, false, true, false, true, false, true, false, true, true, true])
        let mine = try #require(facts.items.first)
        #expect(mine.ref == "group/project!42")
        #expect(mine.details == ["1 of 2 approved", "updated 3 h ago"])
        #expect(mine.link?.absoluteString == "\(gitLab)/-/merge_requests/42")
        #expect(facts.items[2].details == ["by Sam Lee", "updated 3 h ago"])
        // The newest build of each job, its page, and Rebuild.
        let redItem = facts.items[4]
        #expect(redItem.ref == "build:\(red.jobKey)")
        #expect(redItem.link?.absoluteString == "https://jenkins.example.com/job/project/job/MR-42/7/")
        #expect(redItem.rebuild == red.id)
        #expect(facts.items[7].details == ["issue", "slot 2026.49"])
        #expect(facts.items[10].details.first == "1 open item of mine")
        #expect(facts.deadline == DigestFacts.Deadline(slot: "2026.49", text: "Code freeze in 3 days", days: 3, isClose: true))

        // The prompt: each item with its reference in brackets, the date, and the JSON shape.
        let prompt = ClaudePrompt.digest(facts)
        #expect(prompt.schema != nil)
        #expect(prompt.text.contains("Today is Tuesday 2026-11-03."))
        #expect(prompt.text.contains("- [group/project!42] !42 \"Add cart discount\": Ready to merge; 1 of 2 approved; updated 3 h ago"))
        #expect(prompt.text.contains("# Red builds (2)"))
        #expect(prompt.text.contains("Nearest date: 2026.49 code freeze in 3 days"))
        #expect(!prompt.text.contains("Old bug"))
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
        // No checkout on the branch: the user picks one.
        #expect(match(.workItem(other)) == nil)

        // The prompt names the item and its link, and never starts like an option.
        let prompt = ClaudeCodeContext.build(
            build, page: URL(string: "https://ci.example.com/job/project/job/MR-42/7/"),
            failedTests: [FailedTest(className: "a.CartTest", name: "applies", status: .failed, message: "expected:<90>\nmore")]
        ).prompt(in: two)
        #expect(!prompt.hasPrefix("-"))
        #expect(prompt.contains("https://ci.example.com/job/project/job/MR-42/7/"))
        #expect(prompt.contains("a.CartTest.applies"))
        let itemPrompt = ClaudeCodeContext.workItem(item).prompt(in: two)
        #expect(!itemPrompt.hasPrefix("-") && itemPrompt.contains("\(gitLab)/-/issues/1234"))
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
            print -rn -- "$#|$PWD|$1|$2|$3" > '\(record.path(percentEncoded: false))'
            """.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeClaude.path(percentEncoded: false))
        let prompt = "Context: \"quoted\" $(touch pwned) `touch pwned2` ; rm -rf ~ && echo $HOME\nsecond line"

        let launches = folder.url.appending(path: "launches", directoryHint: .isDirectory)
        let script = try ClaudeCodeLaunch.write(
            prompt: prompt, directory: checkout.path(percentEncoded: false), claude: fakeClaude, model: .sonnet, in: launches)
        #expect(try String(contentsOf: script, encoding: .utf8) == ClaudeCodeLaunch.script)
        #expect(!ClaudeCodeLaunch.script.contains("touch"))
        let mode = try FileManager.default.attributesOfItem(atPath: script.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o700)

        // Run it as Terminal would.
        let output = try await SystemProcessRunner().run(URL(filePath: "/bin/zsh"), arguments: [script.path(percentEncoded: false)], input: nil)
        #expect(output.status == 0)
        let recorded = try String(contentsOf: record, encoding: .utf8)
        let parts = recorded.split(separator: "|", maxSplits: 4).map(String.init)
        #expect(parts.first == "3")
        #expect(parts[2] == "--model" && parts[3] == "sonnet")
        #expect(parts.dropFirst().first.map { URL(filePath: $0).resolvingSymlinksInPath().path } == checkout.resolvingSymlinksInPath().path)
        #expect(parts.last == prompt)
        // Nothing in the text ran, and the launch folder is gone.
        for name in ["pwned", "pwned2", "pwned-dir"] {
            #expect(!FileManager.default.fileExists(atPath: checkout.appending(path: name).path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: name).path(percentEncoded: false)))
        }
        #expect(!FileManager.default.fileExists(atPath: script.deletingLastPathComponent().path(percentEncoded: false)))
    }

    @Test("AI-05 Open in Claude Code does nothing when off, opens the script with the user's terminal (Terminal when it can't run one), redacts the prompt and logs no text")
    @MainActor
    func opensTheUsersTerminal() async throws {
        let defaults = TemporaryDefaults()
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url, now: { Date() })
        let fake = FakeClaude(answer: Data())
        let launcher = RecordingLauncher()
        let terminals = FakeTerminals(
            apps: [FakeTerminals.terminal, FakeTerminals.cmux, FakeTerminals.foldersOnly], handler: "com.cmuxterm.app")
        let store = AIStore(
            defaults: defaults.defaults, runner: fake, launcher: launcher, terminals: terminals,
            launchFolder: folder.url.appending(path: "launches", directoryHint: .isDirectory), log: log,
            resolver: fake.resolver(found: true))
        let checkout = Checkout(path: "/work/develop2/project", name: "develop2", baseBranch: "develop", folder: UUID())
        let item = WorkItem(
            reference: "group/project#1234", title: "Rotate password=hunter22 in CI",
            webURL: URL(string: "https://gitlab.example.com/group/project/-/issues/1234")!, updatedAt: Date())

        // Off: nothing opens.
        store.update(AISettings(isEnabled: false))
        await store.openInClaudeCode(.workItem(item), in: checkout)
        #expect(await launcher.calls.isEmpty)

        // Default is the app that opens .command files: cmux here, with the script as the one other argument.
        store.update(AISettings(isEnabled: true))
        await store.openInClaudeCode(.workItem(item), in: checkout)
        let first = try #require(await launcher.calls.first)
        #expect(first.program == "/usr/bin/open")
        #expect(first.arguments.count == 3)
        #expect(Array(first.arguments.prefix(2)) == ["-a", "/Applications/cmux.app"])
        #expect(first.arguments[2].hasSuffix("/" + ClaudeCodeLaunch.scriptName))
        let promptFile = URL(filePath: first.arguments[2]).deletingLastPathComponent().appending(path: "prompt")
        let sent = try String(contentsOf: promptFile, encoding: .utf8)
        #expect(sent.contains("group/project#1234"))
        #expect(!sent.contains("hunter22"))

        // A terminal that can't run a script: Terminal, and it is no problem.
        TerminalChoice.setPreferred("dev.example.folders", in: defaults.defaults)
        await store.openInClaudeCode(.workItem(item), in: checkout)
        let second = try #require(await launcher.calls.last)
        #expect(Array(second.arguments.prefix(2)) == ["-a", "/System/Applications/Utilities/Terminal.app"])
        #expect(store.lastLaunch?.isProblem == false)

        // The log has the launch, never the item's text.
        try await Task.sleep(for: .milliseconds(200))
        let text = await log.entries().map(\.message).joined(separator: "\n")
        #expect(!text.isEmpty)
        #expect(!text.contains("Rotate"))
    }

    // MARK: - AI-01 The model of a run

    @Test("AI-01 a run's model comes from Settings or the click, Ask Again With re-sends the same facts, and Settings' effort reaches the command line once")
    @MainActor
    func modelPerRun() async throws {
        // Through the store: Settings' model by default, the click's model for one run, and Ask Again With re-sends the
        // same facts without gathering them anew.
        let fake = FakeClaude(answer: try FixtureFiles.data("Claude/digest.json"))
        let store = AIStore(defaults: TemporaryDefaults().defaults, runner: fake, resolver: fake.resolver(found: true))
        store.digestFacts = { Self.someFacts }
        store.update(AISettings(isEnabled: true, model: .sonnet, confirmedUseCases: [.digest]))
        await store.writeDigest()
        await store.writeDigest(model: .haiku)
        await store.askAgain(.digest, model: .opus)
        let calls = await fake.claudeCalls
        #expect(!calls.contains { $0.arguments.contains("--effort") })
        let models = calls.map { call in call.arguments[(call.arguments.firstIndex(of: "--model") ?? 0) + 1] }
        #expect(models == ["sonnet", "haiku", "opus"])
        #expect(Set(calls.compactMap(\.input)).count == 1)

        // Settings' effort reaches the command line once.
        store.update(AISettings(isEnabled: true, effort: .high, confirmedUseCases: [.digest]))
        await store.writeDigest()
        let withEffort = try #require(await fake.claudeCalls.last)
        #expect(withEffort.arguments.filter { $0 == "--effort" }.count == 1 && withEffort.arguments.contains("high"))

        // The first send of a use case waits in review; the model chosen with the click is kept for Send.
        let first = AIStore(defaults: TemporaryDefaults().defaults, runner: fake, resolver: fake.resolver(found: true))
        first.digestFacts = { Self.someFacts }
        first.update(AISettings(isEnabled: true))
        await first.writeDigest(model: .haiku)
        await first.send(.digest)
        #expect(await fake.claudeCalls.last?.arguments.contains("haiku") == true)
    }

    @Test("AI-01 the default model reads as Sonnet when none or an unknown one is stored, and a known one is kept")
    func defaultModel() throws {
        #expect(AISettings().model == .sonnet && AISettings().effort == .standard)
        for stored in [#"{}"#, #"{"model":"gpt-9"}"#, #"{"model":42}"#, #"{"model":null}"#] {
            #expect(try JSONDecoder().decode(AISettings.self, from: Data(stored.utf8)).model == .sonnet)
        }
        for stored in [#"{}"#, #"{"effort":"ultra"}"#, #"{"effort":3}"#, #"{"effort":null}"#, #"{"effort":"standard"}"#] {
            #expect(try JSONDecoder().decode(AISettings.self, from: Data(stored.utf8)).effort == .standard)
        }
        #expect(try JSONDecoder().decode(AISettings.self, from: Data(#"{"effort":"xhigh"}"#.utf8)).effort == .xhigh)
        let defaults = TemporaryDefaults()
        AISettings(model: .haiku, effort: .high).save(to: defaults.defaults)
        #expect(AISettings.load(from: defaults.defaults).model == .haiku)
        #expect(AISettings.load(from: defaults.defaults).effort == .high)
    }

    @Test("AI-01 settings saved before the new defaults keep their choices, and a missing key takes the default")
    func savedSettingsKeepTheirChoices() throws {
        let old = #"{"isEnabled":false,"model":"claude-opus-5-5","morningDigest":false,"digestMinutes":480}"#
        let kept = try JSONDecoder().decode(AISettings.self, from: Data(old.utf8))
        #expect(!kept.isEnabled && kept.model == .opus && !kept.morningDigest && kept.digestMinutes == 480)

        // Only what was saved is kept: the model alone leaves the switches at their defaults.
        let partial = try JSONDecoder().decode(AISettings.self, from: Data(#"{"model":"haiku"}"#.utf8))
        #expect(partial.model == .haiku && partial.isEnabled && partial.morningDigest)

        let defaults = TemporaryDefaults()
        AISettings(isEnabled: false, model: .opus, morningDigest: false).save(to: defaults.defaults)
        let loaded = AISettings.load(from: defaults.defaults)
        #expect(!loaded.isEnabled && loaded.model == .opus && !loaded.morningDigest)
    }

    @Test("AI-01 with the Claude features on by default, only the digest and the coffee line run without a click")
    @MainActor
    func silentRuns() async throws {
        let fake = FakeClaude(answer: try FixtureFiles.data("Claude/explain-build.json"))
        let store = AIStore(
            defaults: TemporaryDefaults().defaults, runner: fake, resolver: fake.resolver(found: true))
        await store.detect()
        #expect(store.isOffered && store.settings.confirmedUseCases.isEmpty)
        // A first answer of any kind shows what it sends and waits for Send: nothing was run.
        store.digestFacts = { Self.someFacts }
        await store.writeDigest()
        guard case .review = store.state(of: .digest) else {
            Issue.record("expected the review, got \(store.state(of: .digest))")
            return
        }
        #expect(await fake.claudeCalls.isEmpty)
        // No use case is confirmed until the user sends one or turns the morning digest on and it runs.
        #expect(store.settings.confirmedUseCases.isEmpty)
    }

    @Test("AI-05 the launch script passes --model and --effort only for names of the fixed lists, never a value from a file as code")
    func launchScriptModel() async throws {
        let folder = try TemporaryFolder()
        let record = folder.url.appending(path: "arguments.txt", directoryHint: .notDirectory)
        let fakeClaude = folder.url.appending(path: "claude", directoryHint: .notDirectory)
        try """
            #!/bin/zsh -f
            print -rn -- "$#|${(j:|:)@}" > '\(record.path(percentEncoded: false))'
            """.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeClaude.path(percentEncoded: false))
        let checkout = folder.url.appending(path: "checkout", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)

        let none = "1|first prompt"
        var cases: [(model: String, effort: String, expected: String)] = ClaudeModel.allCases.map {
            ($0.rawValue, "", "3|--model|\($0.rawValue)|first prompt")
        }
        cases += ClaudeEffort.allCases.compactMap(\.level).map { ("", $0, "3|--effort|\($0)|first prompt") }
        cases += [
            ("opus", "high", "5|--model|opus|--effort|high|first prompt"),
            ("claude-opus-5-5", "", none),
            ("opus $(touch pwned)", "", none),
            ("opus; touch pwned", "", none),
            ("", "", none),
            ("", "standard", none),
            ("", "ultra", none),
            ("", "high $(touch pwned)", none),
            ("", "high; touch pwned", none),
            ("", "high --dangerous", none),
        ]
        for (model, effort, expected) in cases {
            let script = try ClaudeCodeLaunch.write(
                prompt: "first prompt", directory: checkout.path(percentEncoded: false), claude: fakeClaude, model: .opus,
                in: folder.url.appending(path: "launches", directoryHint: .isDirectory))
            let launch = script.deletingLastPathComponent()
            try Data(model.utf8).write(to: launch.appending(path: "model"))
            try Data(effort.utf8).write(to: launch.appending(path: "effort"))
            let output = try await SystemProcessRunner().run(URL(filePath: "/bin/zsh"), arguments: [script.path(percentEncoded: false)], input: nil)
            #expect(output.status == 0)
            let recorded = try String(contentsOf: record, encoding: .utf8)
            #expect(recorded == expected, "\(model) / \(effort) ran as \(recorded)")
            #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: "pwned").path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: checkout.appending(path: "pwned").path(percentEncoded: false)))
        }
        // Written from the settings: the model and the effort, nothing when the effort is Default.
        let written = try ClaudeCodeLaunch.write(
            prompt: "p", directory: "/x", claude: fakeClaude, model: .haiku, effort: .xhigh,
            in: folder.url.appending(path: "launches", directoryHint: .isDirectory)).deletingLastPathComponent()
        #expect(try String(contentsOf: written.appending(path: "effort"), encoding: .utf8) == "xhigh")
        #expect(try String(contentsOf: written.appending(path: "model"), encoding: .utf8) == "haiku")
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
        log: FailureLog.narrow(
            "[ERROR] Tests run: 120, Failures: 1\n[ERROR] CartServiceTest.appliesDiscount:42 expected:<90> but was:<100>\n[INFO] BUILD FAILURE\n"))

    static let prompt = ClaudePrompt.explainBuild(failedBuild)

    static let someFacts = DigestFacts(items: [
        DigestItem(
            kind: .mergeRequest, ref: "group/project!42", shortRef: "!42", title: "Add cart discount",
            state: DigestState(text: "Pipeline failed", symbol: "xmark.circle.fill", color: .red), needsYou: true),
        DigestItem(
            kind: .review, ref: "group/project!40", shortRef: "!40", title: "Fix rounding",
            state: DigestState(text: "Waiting on you", symbol: "eye.circle.fill", color: .orange), details: ["by Sam Lee"],
            needsYou: true),
    ])
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
        // `claude --version`, read once when claude is looked for, is not a call the tests count.
        if arguments == ["--version"] {
            return ProcessOutput(status: 0, standardOutput: Data("2.1.317 (Claude Code)\n".utf8))
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
