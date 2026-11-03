import Foundation
import Testing

@testable import MenubarCore

/// AI-10 a free question about a build, whatever its result. Nothing runs the real `claude`: a scripted runner answers.
/// Every log, test, commit and name is made up.
@Suite("Build chat")
struct BuildChatTests {
    @Test("AI-10 the build question's prompt has the stages, the failed tests, the log, the changes and the question last, for a red build")
    func promptForARedBuild() throws {
        var facts = WhyDidItFailTests.facts
        facts.stages = WhyDidItFailTests.build.stages ?? []
        let prompt = ClaudePrompt.buildQuestion(facts, question: "Which stage took longest?")
        #expect(prompt.useCase == .buildChat)
        #expect(prompt.schema == nil, "a free question is answered in Markdown")
        #expect(prompt.question == "Which stage took longest?")
        let text = prompt.text
        let order = ["# Build", "# Stages", "# Failed tests (2)", "# Error markers in the log", "# End of the log", "# Changes", "# My question"]
        let places = try order.map { try #require(text.range(of: $0)?.lowerBound, "\($0)") }
        #expect(places == places.sorted())
        #expect(text.contains("- Checkout: success, 5s"))
        #expect(text.contains("- Unit tests: failed, 300s"))
        #expect(text.contains("!42 #7 \"Add the item count\", result FAILURE"))
        #expect(text.contains("- com.example.cart.CartTest.addsAnItem (regression: passed in the build before)"))
        #expect(text.contains("# Changes: since the last green build (#5), newest first"))
        #expect(text.hasSuffix("# My question\nWhich stage took longest?"))
        #expect(!text.contains("Suspect"), "a free question has changes, not suspects")
        // "Why Did It Fail?" stays what it was: no stages, suspects.
        let why = ClaudePrompt.explainBuild(facts).text
        #expect(!why.contains("# Stages") && why.contains("# Suspect commits"))
    }

    @Test("AI-10 the build question's prompt works for a green build: no failed tests, no suspects, and no secret leaves")
    func promptForAGreenBuildIsRedacted() {
        let facts = BuildFailureFacts(
            title: "Add the item count", job: "!42", number: 8, result: "SUCCESS", testCounts: TestCounts(failed: 0, total: 120),
            changes: [BuildChange(commit: "abc123", author: "Jane Doe", message: "Rotate key sk-ant-api03-abcdefghijklmnopqrstuvwxyz", build: 8)],
            log: FailureLog.narrow("[INFO] deploying with password=hunter22\n[INFO] BUILD SUCCESS\nthe end with my-jenkins-api-token-value\n"),
            stages: [Stage(name: "Checkout", status: .success, duration: 5), Stage(name: "Deploy", status: .notExecuted, duration: 0)])
        let raw = ClaudePrompt.buildQuestion(facts, question: "What did this build deploy?")
        #expect(raw.text.contains("result SUCCESS"))
        #expect(raw.text.contains("# Failed tests: none reported"))
        #expect(raw.text.contains("- Deploy: not executed\n"), "a stage that didn't run has no time")
        // Redacted the way every prompt is, before it is shown or sent.
        let jenkins = Data("jdoe:my-jenkins-api-token-value".utf8).base64EncodedString()
        let sent = raw.redacted(by: SecretRedactor(knownSecrets: [jenkins])).text
        for secret in ["hunter22", "my-jenkins-api-token-value", "sk-ant-api03"] {
            #expect(!sent.contains(secret), "\(secret) is sent")
        }
        #expect(sent.contains("Jane Doe: Rotate key [redacted]"))
    }

    @Test("AI-10 the first question shows what it sends and waits for Send, then a follow-up joins the thread; the chat leaves Why Did It Fail? alone")
    @MainActor
    func confirmsOnceAndFollowsUp() async {
        let fake = ScriptedClaude([.text("The unit tests took longest, five minutes."), .text("Yes, in the same stage.")])
        let store = ConversationTests.store(fake)
        let build = WhyDidItFailTests.build
        let chat = AISubject.buildChat(build.id)
        let prompt = ClaudePrompt.buildQuestion(WhyDidItFailTests.facts, question: "Which stage took longest?")

        await store.ask(chat, model: nil) { prompt }
        guard case .review(let reviewed) = store.state(of: chat) else {
            Issue.record("expected the review, got \(store.state(of: chat))")
            return
        }
        #expect(reviewed.useCase == .buildChat)
        #expect(await fake.calls.isEmpty, "nothing is sent before Send")
        #expect(store.state(of: .build(build.id)) == .idle)

        await store.send(chat)
        #expect(store.settings.confirmedUseCases.contains(.buildChat))
        guard case .answered(let answer) = store.state(of: chat) else {
            Issue.record("expected an answer, got \(store.state(of: chat))")
            return
        }
        #expect(answer.text == "The unit tests took longest, five minutes.")

        await store.followUp(chat, question: "Was it flaky?")
        #expect(store.turns(of: chat).first?.answer == "Yes, in the same stage.")
        let call = await fake.calls.last
        #expect(call?.input?.hasPrefix(prompt.text) == true, "the follow-up carries the facts once")

        // Once sent, this kind of question goes without asking.
        store.dismiss(chat)
        await store.ask(chat, model: nil) { prompt }
        guard case .answered = store.state(of: chat) else {
            Issue.record("expected the second question to run at once, got \(store.state(of: chat))")
            return
        }
        #expect(store.state(of: .build(build.id)) == .idle)
    }

    @Test("AI-10 a question about a build without Jenkins set up says so, and Claude off asks nothing")
    @MainActor
    func withoutJenkinsOrClaude() async {
        let fake = ScriptedClaude([.text("never")])
        let store = ConversationTests.store(fake)
        let build = WhyDidItFailTests.build
        let chat = AISubject.buildChat(build.id)

        await store.ask("Anything odd?", aboutBuild: build, failedTests: nil)
        guard case .failed(let message, _) = store.state(of: chat) else {
            Issue.record("expected a failure, got \(store.state(of: chat))")
            return
        }
        #expect(message == "Jenkins isn't set up")
        #expect(await fake.calls.isEmpty)

        store.update(AISettings(isEnabled: false))
        store.dismiss(chat)
        await store.ask("Anything odd?", aboutBuild: build, failedTests: nil)
        #expect(store.state(of: chat) == .idle)
    }

    @Test("AI-10 the chat's answer lands in the Inbox under its own use case, and Continue in Claude Code knows a green build")
    func namesAndContext() {
        #expect(AISubject.buildChat(WhyDidItFailTests.build.id).useCase == .buildChat)
        #expect(AIUseCase.buildChat.inboxTitle == "Question About a Build")
        #expect(AIUseCase(rawValue: "buildChat") == .buildChat)

        var green = WhyDidItFailTests.build
        green.phase = .finished(result: .success, duration: 600)
        let checkout = Checkout(path: "/work/app", name: "app", baseBranch: "develop", folder: UUID())
        let prompt = ClaudeCodeContext.build(green, page: nil, failedTests: []).prompt(in: checkout)
        #expect(prompt.contains("- Build: !42 #7") && !prompt.contains("Failed build"))
        let red = ClaudeCodeContext.build(WhyDidItFailTests.build, page: nil, failedTests: []).prompt(in: checkout)
        #expect(red.contains("- Failed build: !42 #7"))
    }
}
