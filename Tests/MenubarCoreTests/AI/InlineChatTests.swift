import Foundation
import Testing

@testable import MenubarCore

/// AI-07 and AI-08: the inline chat's scope chip, and stopping a first answer. Nothing runs the real `claude`.
@Suite("Inline Claude chat")
struct InlineChatTests {
    private static let mergeRequest = MergeRequest(
        iid: 42, title: "Add cart discount", webURL: URL(string: "https://example.com/group/project/-/merge_requests/42")!,
        reference: "group/project!42", author: MergeRequest.Person(username: "jdoe", name: "Jane Doe"),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000), roles: [.authored])

    @Test("AI-07 a pick sets the scope chip, the next one replaces it, Clear and the whole merge request take it off")
    @MainActor
    func scopeChip() {
        let store = ConversationTests.store(ScriptedClaude([.text("x")]))
        let mergeRequest = Self.mergeRequest
        let selection = DiffSelection(path: "Sources/Foo.swift", anchor: DiffLineID(old: nil, new: 12), head: DiffLineID(old: nil, new: 30))
        let lines = CodeScope.lines(selection, LineSpan(first: 12, last: 30))
        #expect(store.pendingScope(of: mergeRequest) == nil)

        store.aim(at: lines, of: mergeRequest)
        #expect(store.pendingScope(of: mergeRequest) == lines)
        store.aim(at: .file("Sources/Bar.swift"), of: mergeRequest)
        #expect(store.pendingScope(of: mergeRequest) == .file("Sources/Bar.swift"))
        // Every aim is counted, so that the field takes the focus again.
        #expect(store.aimCount == 2)
        store.clearScope(of: mergeRequest)
        #expect(store.pendingScope(of: mergeRequest) == nil)
        store.aim(at: lines, of: mergeRequest)
        store.aim(at: .mergeRequest, of: mergeRequest)
        #expect(store.pendingScope(of: mergeRequest) == nil)
    }

    @Test("AI-08 stopping a first answer ends claude and leaves the subject stopped, not failed; a work item question comes back")
    @MainActor
    func stopFirstAnswer() async {
        let fake = ScriptedClaude([.hang, .text("Second try.")])
        let store = ConversationTests.store(fake)
        store.update(AISettings(isEnabled: true, confirmedUseCases: [.digest, .askAboutItem]))
        let item = ConversationTests.item
        let subject = AISubject.workItem(item.reference)

        let asking = Task { await store.ask("Why does it matter?", about: item, description: nil) }
        var yields = 0
        while !store.isRunning(subject), yields < 2000 {
            await Task.yield()
            yields += 1
        }
        #expect(store.stop(subject))
        await asking.value
        #expect(store.state(of: subject) == .idle)
        #expect(store.stoppedSubjects.contains(subject))
        #expect(store.openingQuestions[subject] == nil)
        #expect(store.takeStoppedQuestion(of: subject) == "Why does it matter?")
        #expect(store.takeStoppedQuestion(of: subject) == nil)
        // Nothing left to stop; and the late end of the run doesn't turn into a failure.
        #expect(!store.stop(subject))
        #expect(store.state(of: subject) == .idle)

        // Asking again works and clears the note.
        await store.ask("Why does it matter?", about: item, description: nil)
        #expect(!store.stoppedSubjects.contains(subject))
        guard case .answered = store.state(of: subject) else {
            Issue.record("expected an answer, got \(store.state(of: subject))")
            return
        }
    }

    @Test("AI-08 stopping the digest goes back to where it was")
    @MainActor
    func stopDigest() async {
        let store = ConversationTests.store(ScriptedClaude([.text("First digest."), .hang]))
        await store.writeDigest()
        guard case .answered(let first) = store.state(of: .digest) else {
            Issue.record("expected the first digest")
            return
        }
        let again = Task { await store.writeDigest() }
        var yields = 0
        while !store.isRunning(.digest), yields < 2000 {
            await Task.yield()
            yields += 1
        }
        #expect(store.stop(.digest))
        await again.value
        #expect(store.state(of: .digest) == .answered(first))
        #expect(store.stoppedSubjects.contains(.digest))
    }
}

extension AIStore {
    /// whether Claude is answering a subject, to wait for it in a test
    fileprivate func isRunning(_ subject: AISubject) -> Bool {
        if case .running = state(of: subject) { true } else { false }
    }
}
