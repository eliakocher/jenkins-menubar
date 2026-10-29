import Foundation

/// One request to Claude: the app's fixed instructions, the facts, and the shape of the answer (AI-01).
///
/// Only ``instructions`` and ``schema`` may go on `claude`'s command line: they are the app's own text and never hold
/// the user's data. ``text`` holds the facts and goes in through stdin, redacted first (``SecretRedactor``).
public struct ClaudePrompt: Hashable, Sendable {
    public var useCase: AIUseCase
    /// the system prompt: fixed app text
    public var instructions: String
    /// the facts, as sent
    public var text: String
    /// the answer's JSON Schema: fixed app text; `nil` for a text answer
    public var schema: String?

    public init(useCase: AIUseCase, instructions: String, text: String, schema: String? = nil) {
        self.useCase = useCase
        self.instructions = instructions
        self.text = text
        self.schema = schema
    }

    /// Returns the prompt with its facts redacted.
    public func redacted(by redactor: SecretRedactor) -> ClaudePrompt {
        var prompt = self
        prompt.text = redactor.redact(text)
        return prompt
    }

    /// Cuts a text to its last characters, from the start of a line: what the end of a long log needs.
    static func tail(_ text: String, characters: Int) -> String {
        guard text.count > characters else {
            return text
        }
        let end = text.suffix(characters)
        let fromLine = end.firstIndex(of: "\n").map { end[end.index(after: $0)...] } ?? end
        return "[… earlier lines left out …]\n" + fromLine
    }

    /// Cuts a text to its first characters, with an ellipsis.
    static func head(_ text: String, characters: Int) -> String {
        text.count > characters ? String(text.prefix(characters)) + "…" : text
    }

    /// the first line of a text, trimmed
    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

// MARK: - Explain a failed build (AI-02)

/// A commit of a build's changes, from Jenkins's `changeSets`.
public struct BuildChange: Hashable, Sendable {
    /// the commit hash
    public var commit: String
    public var author: String
    /// the commit message's first line
    public var message: String
    /// the build that brought it
    public var build: Int

    public init(commit: String, author: String, message: String, build: Int) {
        self.commit = commit
        self.author = author
        self.message = message
        self.build = build
    }
}

/// What a failed build tells, for "Why Did It Fail?" (AI-02): the build, its failed stages and tests, the changes since
/// the last green build, and the end of its console log.
public struct BuildFailureFacts: Hashable, Sendable {
    /// the MR or branch title
    public var title: String
    /// the job, like `MR-42`
    public var job: String
    public var number: Int
    /// `FAILURE`, `UNSTABLE`
    public var result: String
    public var failedStages: [String]
    /// the test counts, "1 of 120"; `nil` without a test report
    public var testCounts: TestCounts?
    public var failedTests: [FailedTest]
    /// the commits since the last green build, newest first
    public var changes: [BuildChange]
    /// the last successful build's number; `nil` when Jenkins knows none
    public var lastGreen: Int?
    /// the end of the console log
    public var logTail: String

    public init(
        title: String, job: String, number: Int, result: String, failedStages: [String] = [], testCounts: TestCounts? = nil,
        failedTests: [FailedTest] = [], changes: [BuildChange] = [], lastGreen: Int? = nil, logTail: String = ""
    ) {
        self.title = title
        self.job = job
        self.number = number
        self.result = result
        self.failedStages = failedStages
        self.testCounts = testCounts
        self.failedTests = failedTests
        self.changes = changes
        self.lastGreen = lastGreen
        self.logTail = logTail
    }

    /// how much of the log's end is sent: about 4,000 tokens
    public static let logCharacters = 14_000
    /// how many failed tests and changes are listed
    public static let listedTests = 25
    public static let listedChanges = 25
}

extension ClaudePrompt {
    /// the system prompt of "Why Did It Fail?"
    static let explainBuildInstructions = """
        You explain failed CI builds to the developer who owns them, briefly and concretely. Answer only from the facts \
        given; say so when they don't show the cause. "cause": the likely cause in at most three short sentences, naming \
        the failing test, stage or log line. "fix": the most likely fix in one or two sentences. "verdict": "real" for a \
        failure the changes or the code explain, "flaky" for one that looks like timing, infrastructure, network or an \
        unrelated test, "unclear" when the facts don't tell.
        """

    /// the answer's shape of "Why Did It Fail?"
    static let explainBuildSchema = """
        {"type":"object","properties":{"cause":{"type":"string"},"fix":{"type":"string"},\
        "verdict":{"type":"string","enum":["real","flaky","unclear"]}},"required":["cause","fix","verdict"]}
        """

    /// Returns the prompt of "Why Did It Fail?" (AI-02).
    ///
    /// - Parameter facts: the failed build's facts
    /// - Returns: the prompt, not redacted yet
    public static func explainBuild(_ facts: BuildFailureFacts) -> ClaudePrompt {
        var lines = ["A Jenkins build failed. Explain why.", ""]
        lines.append("Build: \(facts.job) #\(facts.number) \"\(facts.title)\", result \(facts.result)")
        if !facts.failedStages.isEmpty {
            lines.append("Failed stages: \(facts.failedStages.joined(separator: ", "))")
        }
        if let counts = facts.testCounts {
            lines.append("Tests: \(counts.failed) of \(counts.total) failed")
        }
        if !facts.failedTests.isEmpty {
            lines.append("")
            lines.append("Failed tests:")
            for test in facts.failedTests.prefix(BuildFailureFacts.listedTests) {
                let name = test.className.isEmpty ? test.name : "\(test.className).\(test.name)"
                let status = test.status == .regression ? " (regression: passed in the build before)" : ""
                let message = test.message.map { ": " + $0.replacingOccurrences(of: "\n", with: " / ") } ?? ""
                lines.append("- \(name)\(status)\(message)")
            }
            if facts.failedTests.count > BuildFailureFacts.listedTests {
                lines.append("- and \(facts.failedTests.count - BuildFailureFacts.listedTests) more")
            }
        }
        lines.append("")
        if let green = facts.lastGreen {
            lines.append(facts.changes.isEmpty
                ? "Changes since the last green build (#\(green)): none"
                : "Changes since the last green build (#\(green)), newest first:")
        } else {
            lines.append(facts.changes.isEmpty
                ? "Changes: none known (no green build in the job's recent history)"
                : "Changes of the recent builds (no green build in the job's recent history), newest first:")
        }
        for change in facts.changes.prefix(BuildFailureFacts.listedChanges) {
            lines.append("- \(change.commit.prefix(10)) #\(change.build) \(change.author): \(head(change.message, characters: 200))")
        }
        if facts.changes.count > BuildFailureFacts.listedChanges {
            lines.append("- and \(facts.changes.count - BuildFailureFacts.listedChanges) more")
        }
        lines.append("")
        lines.append("End of the console log:")
        let log = facts.logTail.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(log.isEmpty ? "(not available)" : tail(log, characters: BuildFailureFacts.logCharacters))
        return ClaudePrompt(
            useCase: .explainBuild, instructions: explainBuildInstructions, text: lines.joined(separator: "\n"),
            schema: explainBuildSchema)
    }
}

// MARK: - Summarize a merge request's discussion (AI-03)

/// A merge request's review thread with all its notes, for the summary (AI-03).
public struct DiscussionThread: Hashable, Sendable {
    /// One note of a thread.
    public struct Note: Hashable, Sendable {
        public var author: MergeRequest.Person?
        /// the note's Markdown, as written
        public var body: String

        public init(author: MergeRequest.Person?, body: String) {
            self.author = author
            self.body = body
        }
    }

    public var resolved: Bool
    /// `src/App.swift:42` for a note on the diff
    public var location: String?
    public var notes: [Note]

    public init(resolved: Bool, location: String? = nil, notes: [Note]) {
        self.resolved = resolved
        self.location = location
        self.notes = notes
    }
}

/// A merge request and its review threads (AI-03).
public struct ThreadsFacts: Hashable, Sendable {
    public var reference: String
    public var title: String
    public var author: MergeRequest.Person
    /// the resolvable threads, unresolved and resolved, oldest first
    public var threads: [DiscussionThread]

    public init(reference: String, title: String, author: MergeRequest.Person, threads: [DiscussionThread]) {
        self.reference = reference
        self.title = title
        self.author = author
        self.threads = threads
    }

    /// the longest note sent, in characters
    public static let noteCharacters = 1_500
    /// the most text sent, in characters: about 10,000 tokens
    public static let totalCharacters = 40_000
}

extension ClaudePrompt {
    static let threadsInstructions = """
        You summarize a merge request's review threads for a developer: what was agreed, what is still open, and who \
        each open point waits on (a person's name, or "the author"). Answer only from the threads given; keep each \
        point to one sentence. Resolved threads count as agreed unless a note says otherwise.
        """

    static let threadsSchema = """
        {"type":"object","properties":{"agreed":{"type":"array","items":{"type":"string"}},\
        "open":{"type":"array","items":{"type":"object","properties":{"point":{"type":"string"},\
        "waitingOn":{"type":"string"}},"required":["point","waitingOn"]}}},"required":["agreed","open"]}
        """

    /// Returns the prompt of "Summarize Discussion" (AI-03): the unresolved threads first, each note cut at
    /// ``ThreadsFacts/noteCharacters``, the whole at ``ThreadsFacts/totalCharacters``.
    ///
    /// - Parameter facts: the merge request and its threads
    /// - Returns: the prompt, not redacted yet
    public static func summarizeThreads(_ facts: ThreadsFacts) -> ClaudePrompt {
        func person(_ person: MergeRequest.Person?) -> String {
            guard let person else {
                return "Someone"
            }
            return person.name.isEmpty ? person.username : "\(person.name) (\(person.username))"
        }
        var text = "Summarize the review discussion of this merge request.\n\n"
        text += "Merge request: \(facts.reference) \"\(facts.title)\" by \(person(facts.author))\n"
        let ordered = facts.threads.filter { !$0.resolved } + facts.threads.filter(\.resolved)
        var left = 0
        for (index, thread) in ordered.enumerated() {
            var part = "\nThread \(index + 1) (\(thread.resolved ? "resolved" : "unresolved"))"
            if let location = thread.location {
                part += " on \(location)"
            }
            part += "\n"
            for note in thread.notes {
                let body = head(note.body.trimmingCharacters(in: .whitespacesAndNewlines), characters: ThreadsFacts.noteCharacters)
                part += "- \(person(note.author)): \(body.replacingOccurrences(of: "\n", with: "\n  "))\n"
            }
            guard text.count + part.count <= ThreadsFacts.totalCharacters else {
                left = ordered.count - index
                break
            }
            text += part
        }
        if left > 0 {
            text += "\n(\(left) more threads left out for length)\n"
        }
        if ordered.isEmpty {
            text += "\n(no review threads)\n"
        }
        return ClaudePrompt(
            useCase: .summarizeThreads, instructions: threadsInstructions,
            text: text.trimmingCharacters(in: .newlines), schema: threadsSchema)
    }
}

// MARK: - The daily digest (AI-04)

/// What the digest is written from, as lines of facts from the app's own stores (AI-04).
public struct DigestFacts: Hashable, Sendable {
    public var myMergeRequests: [String]
    public var reviews: [String]
    public var redBuilds: [String]
    /// the work items by slot, the slots in order; `nil` for the items without one
    public var workItemsBySlot: [Slot]

    /// The work items of one slot.
    public struct Slot: Hashable, Sendable {
        /// the slot's name; `nil` for no slot
        public var name: String?
        public var items: [String]

        public init(name: String?, items: [String]) {
            self.name = name
            self.items = items
        }
    }

    public init(myMergeRequests: [String] = [], reviews: [String] = [], redBuilds: [String] = [], workItemsBySlot: [Slot] = []) {
        self.myMergeRequests = myMergeRequests
        self.reviews = reviews
        self.redBuilds = redBuilds
        self.workItemsBySlot = workItemsBySlot
    }

    /// whether there is nothing to write about
    public var isEmpty: Bool {
        myMergeRequests.isEmpty && reviews.isEmpty && redBuilds.isEmpty && workItemsBySlot.allSatisfy(\.items.isEmpty)
    }

    /// how many lines each part lists at most
    public static let listedPerPart = 20

    /// Gathers the digest's facts from what the app has loaded.
    ///
    /// - Parameters:
    ///   - mergeRequests: the merge requests in their sections; `nil` before the first load
    ///   - builds: the builds Pipelines follows, mine and watched
    ///   - workItems: the work items; `nil` before the first load
    ///   - slotPrefix: the slot label prefix from Team; empty means no slots
    ///   - now: the current time, for the ages
    /// - Returns: the facts
    public static func gather(
        mergeRequests: MergeRequestSections?, builds: [Build], workItems: [WorkItem], slotPrefix: String, now: Date
    ) -> DigestFacts {
        func age(_ date: Date) -> String {
            let hours = Int(now.timeIntervalSince(date) / 3600)
            return hours < 1 ? "updated within the hour" : hours < 48 ? "updated \(hours) h ago" : "updated \(hours / 24) days ago"
        }
        func line(_ mergeRequest: MergeRequest) -> String {
            var parts = ["\(mergeRequest.reference) \"\(mergeRequest.title)\""]
            if mergeRequest.isDraft {
                parts.append("draft")
            }
            if let pipeline = mergeRequest.pipelineStatus {
                parts.append("pipeline \(pipeline.rawValue.lowercased())")
            }
            if let status = mergeRequest.mergeStatus {
                parts.append("merge status \(status.rawValue.lowercased())")
            }
            let approved = mergeRequest.reviewers.filter(\.approved).count
            if !mergeRequest.reviewers.isEmpty {
                parts.append("\(approved) of \(mergeRequest.reviewers.count) reviewers approved")
            }
            parts.append(age(mergeRequest.updatedAt))
            return parts.joined(separator: ", ")
        }
        let mine = (mergeRequests?.yours ?? []).prefix(listedPerPart).map(line)
        let reviews = (mergeRequests?.reviewRequested ?? []).prefix(listedPerPart).map { mergeRequest in
            "\(line(mergeRequest)), by \(mergeRequest.author.name.isEmpty ? mergeRequest.author.username : mergeRequest.author.name)"
        }
        let red = builds.filter { $0.result == .failure || $0.result == .unstable }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(listedPerPart)
            .map { build in
                var parts = ["\(build.label) #\(build.number)\(build.title.map { " \"\($0)\"" } ?? "")",
                             build.result?.rawValue ?? "FAILURE"]
                if let stages = build.failedStages, !stages.isEmpty {
                    parts.append("failed stages \(stages.joined(separator: ", "))")
                }
                if let tests = build.testCounts, tests.failed > 0 {
                    parts.append("\(tests.failed) of \(tests.total) tests failed")
                }
                if build.kind == .watched {
                    parts.append("watched")
                }
                return parts.joined(separator: ", ")
            }
        var slots: [String?: [String]] = [:]
        var order: [String?] = []
        for item in workItems.prefix(listedPerPart * 2) where item.state != .closed {
            let slot = item.slot(prefix: slotPrefix)
            if slots[slot] == nil {
                order.append(slot)
            }
            slots[slot, default: []].append("\(item.reference) \"\(item.title)\" (\(item.type.rawValue.lowercased()))")
        }
        // The named slots in their order, the items without one last.
        let named = order.compactMap { $0 }.sorted()
        var bySlot = named.map { Slot(name: $0, items: slots[$0] ?? []) }
        if let none = slots[nil] {
            bySlot.append(Slot(name: nil, items: none))
        }
        return DigestFacts(myMergeRequests: Array(mine), reviews: Array(reviews), redBuilds: Array(red), workItemsBySlot: bySlot)
    }
}

extension ClaudePrompt {
    static let digestInstructions = """
        You write a developer's short daily digest from the facts given: plain sentences, no headings, no Markdown \
        tables, at most 8 lines. Start with what needs them first (red builds of their own, reviews waiting long, merge \
        requests that are blocked), then the rest. Don't invent anything the facts don't say.
        """

    /// Returns the prompt of the daily digest (AI-04).
    ///
    /// - Parameter facts: the facts from the app's stores
    /// - Returns: the prompt, not redacted yet
    public static func digest(_ facts: DigestFacts) -> ClaudePrompt {
        func part(_ title: String, _ lines: [String]) -> String {
            "\(title) (\(lines.count)):\n" + (lines.isEmpty ? "- none" : lines.map { "- \($0)" }.joined(separator: "\n"))
        }
        var parts = [
            "Write my daily digest from these facts.",
            part("My merge requests", facts.myMergeRequests),
            part("Reviews waiting for me", facts.reviews),
            part("Red builds", facts.redBuilds),
        ]
        var items = "Work items by slot:"
        if facts.workItemsBySlot.isEmpty {
            items += "\n- none"
        }
        for slot in facts.workItemsBySlot {
            items += "\n- \(slot.name ?? "no slot"): " + slot.items.joined(separator: "; ")
        }
        parts.append(items)
        return ClaudePrompt(useCase: .digest, instructions: digestInstructions, text: parts.joined(separator: "\n\n"))
    }
}
