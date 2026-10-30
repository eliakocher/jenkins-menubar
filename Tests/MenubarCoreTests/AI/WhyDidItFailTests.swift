import Foundation
import Testing

@testable import MenubarCore

/// AI-02 "Why Did It Fail?": the log narrowed to its error markers, the gathering from Jenkins, the prompt and the
/// answer. Every log, test, commit and name is made up.
@Suite("Why Did It Fail?")
struct WhyDidItFailTests {
    // MARK: - The log narrowing

    @Test(
        "AI-02 narrows the log to its error markers: compiler errors, test failures, exceptions, build failures, timeouts, infrastructure",
        arguments: [
            ("[ERROR] /work/src/main/java/com/example/cart/CartService.java:[57,21] cannot find symbol", FailureLog.Kind.compiler),
            ("Sources/Cart/Cart.swift:12:5: error: cannot convert value of type 'Int' to 'String'", .compiler),
            ("src/cart.ts(12,5): error TS2345: Argument of type 'string' is not assignable", .compiler),
            ("[ERROR] COMPILATION ERROR :", .compiler),
            ("[ERROR] Tests run: 12, Failures: 1, Errors: 0, Skipped: 0, Time elapsed: 0.4 s <<< FAILURE! - in com.example.CartTest", .testFailure),
            ("Tests run: 12, Failures: 0, Errors: 2, Skipped: 0", .testFailure),
            ("12:00:01 Runner#com.example.cart.CartTest#addsAnItem: failed (ERROR): java.lang.IllegalStateException", .testFailure),
            ("FAILED tests/test_cart.py::test_adds - AssertionError: assert 1 == 2", .testFailure),
            ("Caused by: java.lang.IllegalStateException: the cart is closed", .exception),
            ("Exception in thread \"main\" java.lang.NullPointerException", .exception),
            ("Traceback (most recent call last):", .exception),
            ("[INFO] BUILD FAILURE", .buildFailure),
            ("ERROR: script returned exit code 2", .buildFailure),
            ("[ERROR] Failed to execute goal org.example.plugins:example-plugin:1.0:run (default) on project cart", .buildFailure),
            ("Timeout has been exceeded", .timeout),
            ("Cancelling nested steps due to timeout", .timeout),
            ("java.util.concurrent.TimeoutException: waited 30 seconds for the cart service", .timeout),
            ("java.io.IOException: No space left on device", .infrastructure),
            ("Cannot contact agent-7: java.lang.InterruptedException", .infrastructure),
            ("curl: (6) Could not resolve host: registry.example.com", .infrastructure),
            ("docker: Error response from daemon: toomanyrequests: rate limit exceeded", .infrastructure),
            ("/work/run.sh: line 3:  4242 Killed                  java -jar cart.jar", .infrastructure),
            ("2026-10-29 12:00:01.123 ERROR c.e.cart.CartJob - the nightly job stopped", .error),
        ])
    func marksEachKind(_ line: String, _ kind: FailureLog.Kind) {
        let log = FailureLog.narrow("[INFO] starting\n\(line)\n[INFO] done\n")
        #expect(log.excerpts.count == 1)
        #expect(log.excerpts.first?.kinds == [kind], "\(line)")
        #expect(log.excerpts.first?.marked == [2])
    }

    @Test("AI-02 the log narrowing leaves ordinary lines, stack frames and Jenkins's own lines unmarked")
    func leavesOrdinaryLines() {
        let quiet = """
            [INFO] Tests run: 120, Failures: 0, Errors: 0, Skipped: 0
            \tat com.example.cart.CartService.add(CartService.java:57)
            [Pipeline] { (Error handling)
            Downloading error-prone-annotations-2.3.jar
            [INFO] BUILD SUCCESS
            Finished: FAILURE
            """
        let log = FailureLog.narrow(quiet)
        #expect(log.excerpts.isEmpty)
        #expect(log.markedCount == 0)
        // Without a marked line, the end goes whole, without Jenkins's own lines.
        #expect(log.tail.hasSuffix("Finished: FAILURE"))
        #expect(!log.tail.contains("[Pipeline]"))
    }

    @Test("AI-02 keeps a few lines around each marked line, joins the ones that touch, and names the stage")
    func contextAndStages() throws {
        let log = FailureLog.narrow(Self.pipelineLog)
        #expect(log.stageStarts["Checkout"] == 2)
        #expect(log.stageStarts["Unit tests"] == 6)

        let tests = try #require(log.excerpts.first)
        // Lines 9 to 11 are marked; two lines before the first, three after the last, joined into one.
        #expect(tests.firstLine == 7)
        #expect(tests.marked == [9, 10, 11])
        #expect(tests.lastLine == 14)
        #expect(tests.kinds == [.testFailure])
        #expect(tests.stage == "Unit tests")
        #expect(tests.lines.contains("\tat com.example.cart.CartTest.addsAnItem(CartTest.java:12)"))
        #expect(log.firstMarkedLine(inStages: ["Unit tests", "Checkout"]) == ["Unit tests": 9])

        // The final failure, far away, is its own excerpt, cut at the log's end; the colors are gone.
        let end = try #require(log.excerpts.last)
        #expect(log.excerpts.count == 2)
        #expect(end.marked == [log.lineCount - 1])
        #expect(end.lastLine == log.lineCount)
        #expect(end.stage == nil)
        #expect(end.lines.contains("[INFO] BUILD FAILURE"))
        #expect(!end.lines.joined().contains("\u{1B}"))
        // The excerpts reach the end: nothing is repeated as its end.
        #expect(log.tail.isEmpty)

        // Far from the end, the last lines follow, without Jenkins's own.
        let longer = FailureLog.narrow(Self.pipelineLog + (1...100).map { "[Pipeline] echo\nstep \($0)" }.joined(separator: "\n"))
        #expect(longer.tail.hasSuffix("step 100"))
        #expect(longer.tail.split(separator: "\n").count <= FailureLog.tailLines)
        #expect(!longer.tail.contains("[Pipeline]"))
    }

    @Test("AI-02 counts a repeated marked line once, and caps the excerpts by kind and by length, the compiler error first")
    func dedupeAndCaps() throws {
        var lines = (1...50).map { "[WARN] cache-\($0) Connection refused after \($0 * 10) ms" }
        // Forty different failed tests, then one compiler error at the end.
        let words = ["Cart", "Order", "Payment", "Invoice", "Coupon", "Basket", "Stock", "Price"]
        for first in words {
            for second in words.prefix(5) {
                lines.append("Runner#com.example.\(first)\(second)Test#works: failed (FAILURE): expected")
                lines.append("filler")
            }
        }
        lines.append("[ERROR] /work/src/main/java/com/example/cart/Cart.java:[9,1] cannot find symbol")
        let log = FailureLog.narrow(lines.joined(separator: "\n"))

        let refused = try #require(log.excerpts.first { $0.kinds.contains(.infrastructure) })
        #expect(refused.repeats == 50)
        #expect(log.excerpts.filter { $0.kinds.contains(.infrastructure) }.count == 1)
        #expect(log.excerpts.flatMap(\.marked).filter { lines[$0 - 1].contains("Test#works") }.count == FailureLog.perKind)
        #expect(log.excerpts.last?.kinds == [.compiler])
        #expect(log.markedCount == 1 + 40 + 1)
        #expect(log.leftOut == 40 - FailureLog.perKind)

        // Long lines: cut at lineCharacters, and the excerpts stop at excerptCharacters, the earliest kept.
        let long = (0..<6).flatMap { index in
            ["ERROR step \(["a", "b", "c", "d", "e", "f"][index]) " + String(repeating: "x", count: 500)]
                + Array(repeating: String(repeating: "y", count: 400), count: 8)
        }
        let capped = FailureLog.narrow(long.joined(separator: "\n"))
        let characters = capped.excerpts.flatMap(\.lines).reduce(0) { $0 + $1.count + 8 }
        #expect(characters <= FailureLog.excerptCharacters)
        #expect(capped.leftOut > 0)
        #expect(capped.excerpts.first?.marked == [1])
        #expect(capped.excerpts.flatMap(\.lines).allSatisfy { $0.count <= FailureLog.lineCharacters + 1 })
    }

    // MARK: - The gathering

    @Test("AI-02 gathers the failed tests, the narrowed log and the suspect commits from Jenkins, the detail's tests first")
    func gathers() async throws {
        let stub = StubTransport()
        stub.answer(path: "/job/project/job/MR-42/7/consoleText", body: Self.pipelineLog)
        stub.answer(path: "/job/project/job/MR-42/api/json", body: """
            {"lastSuccessfulBuild": {"number": 5},
             "builds": [
               {"number": 7, "changeSets": [{"items": [
                  {"commitId": "c71", "msg": "Add the item count", "author": {"fullName": "Jane Doe"}},
                  {"commitId": "c72", "msg": "Round the total\\n\\nwith a body", "author": {"fullName": "Kim Park"}}]}]},
               {"number": 6, "changeSets": [], "changeSet": {"items": [{"commitId": "c6", "msg": "Six", "author": null}]}},
               {"number": 5, "changeSets": [{"items": [{"commitId": "c5", "msg": "Green", "author": {"fullName": "Sam Lee"}}]}]}
             ]}
            """)
        stub.answer(path: "/job/project/job/MR-42/7/testReport/api/json", body: """
            {"suites": [{"cases": [
              {"className": "com.example.cart.CartTest", "name": "addsAnItem", "status": "FAILED",
               "errorDetails": "expected:<2> but was:<1>", "age": 3},
              {"className": "com.example.cart.CartTest", "name": "removes", "status": "PASSED", "age": 0}]}]}
            """)
        let client = JenkinsClient(jobURL: URL(string: "https://ci.example.com/job/project/")!, token: "dG9rZW4=", transport: stub)
        let build = Self.build

        let facts = try await BuildFailureFacts.gather(
            build, failedTests: nil, flakyHints: [.failedBefore(stage: "Unit tests", failed: 3, of: 10)], client: client)
        #expect(facts.job == "!42")
        #expect(facts.failedStages == ["Unit tests"])
        #expect(facts.failedTests == [FailedTest(
            className: "com.example.cart.CartTest", name: "addsAnItem", status: .failed, message: "expected:<2> but was:<1>",
            age: 3)])
        #expect(facts.log.excerpts.first?.marked == [9, 10, 11])
        #expect(facts.lastGreen == 5)
        #expect(facts.changes.map(\.commit) == ["c72", "c71", "c6"])
        #expect(facts.changes.first?.author == "Kim Park")
        #expect(facts.changes.map(\.message) == ["Round the total", "Add the item count", "Six"])
        #expect(facts.changes.last?.author == "Someone")
        #expect(facts.flakyHints.count == 1)
        let report = try #require(stub.requests(path: "/job/project/job/MR-42/7/testReport/api/json").first)
        #expect(report.url.query(percentEncoded: false)?.contains("age") == true)

        // The detail's tests are taken as they are: the report isn't read again.
        let shown = [FailedTest(className: "a.B", name: "c", status: .regression)]
        let again = try await BuildFailureFacts.gather(build, failedTests: shown, client: client)
        #expect(again.failedTests == shown)
        #expect(stub.requests(path: "/job/project/job/MR-42/7/testReport/api/json").count == 1)

        // Without the log there is nothing to investigate; without the commits, the facts say so.
        let bare = StubTransport()
        bare.answer(path: "/job/project/job/MR-42/7/consoleText", status: 500)
        let none = JenkinsClient(jobURL: URL(string: "https://ci.example.com/job/project/")!, token: "dG9rZW4=", transport: bare)
        await #expect(throws: AIGatherError.self) {
            _ = try await BuildFailureFacts.gather(build, failedTests: [], client: none)
        }
        bare.answer(path: "/job/project/job/MR-42/7/consoleText", body: "[INFO] BUILD FAILURE\n")
        let noChanges = try await BuildFailureFacts.gather(build, failedTests: [], client: none)
        #expect(noChanges.changes.isEmpty)
        #expect(noChanges.lastGreen == nil)
    }

    // MARK: - The prompt and the answer

    @Test("AI-02 the failed build's prompt has the build, the failed tests, the log's error markers, its end and the suspect commits, in that order")
    func prompt() throws {
        let prompt = ClaudePrompt.explainBuild(Self.facts)
        #expect(prompt.useCase == .explainBuild)
        for part in ["headline", "verdict", "infrastructure", "failedAt", "evidence", "suspects", "nextStep"] {
            #expect(prompt.schema?.contains("\"\(part)\"") == true, "\(part)")
        }
        let text = prompt.text
        let order = ["# Build", "# Failed tests (2)", "# Error markers in the log", "# End of the log", "# Suspect commits"]
        let places = try order.map { try #require(text.range(of: $0)?.lowerBound, "\($0)") }
        #expect(places == places.sorted())

        #expect(text.contains("!42 #7 \"Add the item count\", result FAILURE"))
        #expect(text.contains("Failed stages: Unit tests (starts at log line 6, first error marker at line 9)"))
        #expect(text.contains("Tests: 2 of 120 failed"))
        #expect(text.contains("History: stage \"Unit tests\" failed in 4 of the last 10 builds"))
        #expect(text.contains("- com.example.cart.CartTest.addsAnItem (regression: passed in the build before): expected:<2> but was:<1>"))
        #expect(text.contains("- com.example.cart.OrderTest.ships (failing for 4 builds in a row): Timed out after 30 seconds"))
        #expect(text.contains("## line 9, 10, 11, stage \"Unit tests\", test failure"))
        #expect(text.contains(">10 | [ERROR] com.example.cart.CartTest.addsAnItem  Time elapsed: 0.1 s  <<< FAILURE!"))
        #expect(text.contains(" 12 | \tat com.example.cart.CartTest.addsAnItem(CartTest.java:12)"))
        #expect(text.contains("# Suspect commits: since the last green build (#5), newest first"))
        #expect(text.contains("- 1a2b3c4d5e #7 Jane Doe: Count only the new items"))
        #expect(!text.contains("[Pipeline] }"), "the end of the log keeps Jenkins's own lines out")
        // About 4,000 characters for a small build; a large log stays within its caps.
        #expect(text.count < 4_000)

        var bare = Self.facts
        bare.failedTests = []
        bare.changes = []
        bare.lastGreen = nil
        bare.log = FailureLog.narrow((1...5000).map { "step \($0)" }.joined(separator: "\n"))
        let quiet = ClaudePrompt.explainBuild(bare).text
        #expect(quiet.contains("# Failed tests: none reported"))
        #expect(quiet.contains("# Error markers in the log: none found in 5000 lines"))
        #expect(quiet.hasSuffix("# Suspect commits: none known (no green build in the job's recent history)"))
        #expect(quiet.contains("step 5000"))
        #expect(!quiet.contains("step 1\n"))
        #expect(quiet.count < FailureLog.bareTailCharacters + 1_000)
    }

    @Test("AI-02 the investigation's secrets are redacted: the log's excerpts, its end, the tests and the commits")
    func redactsTheInvestigation() {
        var facts = Self.facts
        facts.log = FailureLog.narrow("""
            [INFO] deploying with password=hunter22
            [ERROR] upload failed: Authorization: Bearer glpat-abcdefghij0123456789
            [INFO] BUILD FAILURE
            the end with my-jenkins-api-token-value
            """)
        facts.failedTests = [FailedTest(className: "a.LoginTest", name: "logs", status: .failed, message: "token ghp_abcdefghijklmnopqrstuvwxyz0123456789 refused")]
        facts.changes = [BuildChange(commit: "abc", author: "Jane Doe", message: "Rotate key sk-ant-api03-abcdefghijklmnopqrstuvwxyz", build: 7)]
        let raw = ClaudePrompt.explainBuild(facts)
        // The secrets did reach the prompt through the narrowing, before the redaction.
        #expect(raw.text.contains("hunter22"))
        #expect(raw.text.contains("glpat-abcdefghij0123456789"))

        let jenkins = Data("jdoe:my-jenkins-api-token-value".utf8).base64EncodedString()
        let sent = raw.redacted(by: SecretRedactor(knownSecrets: [jenkins])).text
        for secret in ["hunter22", "glpat-abcdefghij0123456789", "my-jenkins-api-token-value", "ghp_abcdefghij", "sk-ant-api03"] {
            #expect(!sent.contains(secret), "\(secret) is sent")
        }
        #expect(sent.contains("upload failed: Authorization: Bearer [redacted]"))
        #expect(sent.contains("a.LoginTest.logs"))
        #expect(sent.contains("Jane Doe: Rotate key [redacted]"))
    }

    @Test("AI-02 reads the investigation: the verdict, where it failed, the cause, the evidence, the suspects and the next step")
    @MainActor
    func readsTheAnswer() throws {
        // A real `claude -p` answer (Opus 5.5, 2026-10-29) to the prompt of the made-up facts below.
        let run = try ClaudeRun.parse(FixtureFiles.data("Claude/explain-build-investigation.json"))
        let prompt = ClaudePrompt.explainBuild(Self.facts)
        let answer = try #require(AIStore.answer(of: run, prompt: prompt, model: .opus, at: Date())?.explanation)
        #expect(answer.verdict == .real)
        #expect(answer.headline.split(separator: " ").count <= 12)
        #expect(answer.failedAt.contains("Unit tests"))
        #expect(answer.cause.contains("addsAnItem"))
        #expect(answer.evidence.contains("java.lang.AssertionError: expected:<2> but was:<1>"))
        #expect(answer.suspects.map(\.commit) == ["1a2b3c4d5e"])
        #expect(answer.suspects.first?.author == "Jane Doe")
        #expect(!answer.nextStep.isEmpty)

        // Only lines that were sent show as evidence; a line number in front is taken off.
        let checked = BuildExplanation(
            verdict: .real, cause: "c",
            evidence: ["Line 11: java.lang.AssertionError: expected:<2> but was:<1>", ">10 | [INFO] BUILD FAILURE",
                       "The test regressed, see above", "  "],
            nextStep: "n"
        ).keepingEvidence(in: prompt.text)
        #expect(checked.evidence == ["java.lang.AssertionError: expected:<2> but was:<1>", "[INFO] BUILD FAILURE"])

        // An infrastructure verdict; an answer of the first shape reads with its fix as the next step.
        let infrastructure = ClaudeRun(text: """
            {"headline":"The agent ran out of disk","verdict":"infrastructure","failedAt":"Build","cause":"c",\
            "evidence":["No space left on device",""],"suspects":[],"nextStep":"Rebuild"}
            """)
        let read = try #require(infrastructure.decoded(BuildExplanation.self))
        #expect(read.verdict == .infrastructure)
        #expect(read.evidence == ["No space left on device"])
        #expect(ClaudeRun(text: "{\"cause\":\"c\",\"fix\":\"f\",\"verdict\":\"real\"}").decoded(BuildExplanation.self)
            == BuildExplanation(verdict: .real, cause: "c", nextStep: "f"))
    }

    // MARK: - Made-up values

    /// A made-up pipeline log: a checkout stage, a unit test stage with one failed test, and the end.
    static let pipelineLog = """
        [Pipeline] stage
        [Pipeline] { (Checkout)
        Cloning https://git.example.com/group/project.git
        [Pipeline] }
        [Pipeline] stage
        [Pipeline] { (Unit tests)
        [INFO] Running com.example.cart.CartTest
        [INFO] Running com.example.cart.OrderTest
        [ERROR] Tests run: 3, Failures: 1, Errors: 0, Skipped: 0, Time elapsed: 0.2 s <<< FAILURE! - in com.example.cart.CartTest
        [ERROR] com.example.cart.CartTest.addsAnItem  Time elapsed: 0.1 s  <<< FAILURE!
        java.lang.AssertionError: expected:<2> but was:<1>
        \tat com.example.cart.CartTest.addsAnItem(CartTest.java:12)
        \tat com.example.runner.Runner.run(Runner.java:40)
        \tat com.example.runner.Runner.main(Runner.java:12)
        [INFO] Results:
        [INFO] uploading the report
        [INFO] report uploaded
        [INFO] cleaning up
        [INFO] cleaned up
        [INFO] ------------------------------------------------------------------------
        [Pipeline] }
        [Pipeline] // stage
        \u{1B}[1;31m[INFO] BUILD FAILURE\u{1B}[0m
        Finished: FAILURE

        """

    static let build = Build(
        job: "MR-42", number: 7, title: "Add the item count", kind: .mine,
        phase: .finished(result: .failure, duration: 600), startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        stages: [Stage(name: "Checkout", status: .success, duration: 5), Stage(name: "Unit tests", status: .failed, duration: 300)],
        testCounts: TestCounts(failed: 2, total: 120))

    static let facts = BuildFailureFacts(
        title: "Add the item count", job: "!42", number: 7, result: "FAILURE", failedStages: ["Unit tests"],
        testCounts: TestCounts(failed: 2, total: 120),
        failedTests: [
            FailedTest(
                className: "com.example.cart.CartTest", name: "addsAnItem", status: .regression, message: "expected:<2> but was:<1>"),
            FailedTest(
                className: "com.example.cart.OrderTest", name: "ships", status: .failed, message: "Timed out after 30 seconds", age: 4),
        ],
        changes: [BuildChange(commit: "1a2b3c4d5e6f", author: "Jane Doe", message: "Count only the new items", build: 7)],
        lastGreen: 5, log: FailureLog.narrow(pipelineLog),
        flakyHints: [.failedBefore(stage: "Unit tests", failed: 4, of: 10)])
}
