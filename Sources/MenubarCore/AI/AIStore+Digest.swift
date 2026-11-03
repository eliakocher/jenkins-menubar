import Foundation

extension AIStore {
    /// Completes the digest's answer (AI-04): its cards from the facts that were sent and Claude's JSON, with what changed
    /// since the digest before, which the preferences keep. Claude's answer in words keeps its text, shown as Markdown.
    ///
    /// - Parameters:
    ///   - answer: the answer as read from the run
    ///   - run: the run
    /// - Returns: the answer; `nil` when it has neither cards nor text
    func completeDigest(_ answer: AIAnswer, run: ClaudeRun) -> AIAnswer? {
        var answer = answer
        var history = DigestHistory.load(from: defaults)
        if let facts = digestSent {
            let changes = history.record(facts)
            if let reply = DigestReply.parse(structured: run.structured, text: run.text) {
                answer.digest = DigestReport(facts: facts, reply: reply, changes: changes)
            }
        }
        let written = answer.digest != nil || answer.text != nil
        if !written {
            // A failed digest is nothing to look at.
            history.markSeen()
        }
        history.save(to: defaults)
        if written {
            store(answer)
        }
        hasUnreadDigest = written && history.hasUnread
        return written ? answer : nil
    }

    /// Marks the digest as seen, for the Digest section showing it: the sidebar's dot goes, and stays gone after a
    /// relaunch. Does nothing while there is no unread digest.
    public func markDigestSeen() {
        guard hasUnreadDigest else {
            return
        }
        var history = DigestHistory.load(from: defaults)
        history.markSeen()
        history.save(to: defaults)
        hasUnreadDigest = false
    }
}

// MARK: - The last digest, kept for the next launch

/// The last digest as the file keeps it: what the page shows, with the time it was written, the model and what was sent.
struct StoredDigest: Codable {
    /// the file's shape; a file of another version is not read
    var version = 1
    var report: DigestReport?
    var text: String?
    var model: String
    var answeredAt: Date
    var instructions: String
    var prompt: String
    var schema: String?

    init(_ answer: AIAnswer) {
        report = answer.digest
        text = answer.text
        model = answer.model
        answeredAt = answer.answeredAt
        instructions = answer.prompt.instructions
        prompt = answer.prompt.text
        schema = answer.prompt.schema
    }

    var answer: AIAnswer {
        AIAnswer(
            text: text, digest: report, model: model,
            prompt: ClaudePrompt(useCase: .digest, instructions: instructions, text: prompt, schema: schema),
            answeredAt: answeredAt)
    }
}

extension AIStore {
    /// File name of the last digest in the application support folder.
    public static let digestFileName = "last-digest.json"

    /// Shows the digest of the last launch again and sets the dot. A file that is missing, from another version or
    /// unreadable shows no digest and no dot, so the dot never points at an empty page.
    func restoreDigest() {
        guard let digestFile, let data = try? Data(contentsOf: digestFile),
            let stored = try? JSONDecoder().decode(StoredDigest.self, from: data), stored.version == 1,
            stored.report != nil || stored.text != nil
        else {
            hasUnreadDigest = false
            return
        }
        states[.digest] = .answered(stored.answer)
        hasUnreadDigest = DigestHistory.load(from: defaults).hasUnread
    }

    /// Keeps the digest for the next launch. A failure to write costs only the page after a relaunch.
    func store(_ answer: AIAnswer) {
        guard let digestFile else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: digestFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            try encoder.encode(StoredDigest(answer)).write(to: digestFile, options: .atomic)
        } catch {
            record("Claude: couldn't keep the digest for the next launch", level: .warning, source: .app)
        }
    }

    /// Deletes the kept digest, for Clear, and takes the dot away.
    func forgetStoredDigest() {
        if let digestFile {
            try? FileManager.default.removeItem(at: digestFile)
        }
        hasUnreadDigest = false
    }
}
