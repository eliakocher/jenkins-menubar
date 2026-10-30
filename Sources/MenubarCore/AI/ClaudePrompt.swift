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

/// What a failed build tells, for "Why Did It Fail?" (AI-02), gathered the way a developer investigates one: the build
/// and where it failed, its failed tests with their messages, the log narrowed to its error markers, whether the stages
/// failed before, and the suspect commits since the last green build.
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
    /// the console log, narrowed to its error markers
    public var log: FailureLog
    /// what the job's recent builds say of the failed stages (PIPE-10); empty when unknown
    public var flakyHints: [FlakyHint]

    public init(
        title: String, job: String, number: Int, result: String, failedStages: [String] = [], testCounts: TestCounts? = nil,
        failedTests: [FailedTest] = [], changes: [BuildChange] = [], lastGreen: Int? = nil, log: FailureLog = FailureLog(),
        flakyHints: [FlakyHint] = []
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
        self.log = log
        self.flakyHints = flakyHints
    }

    /// how many failed tests and changes are listed
    public static let listedTests = 25
    public static let listedChanges = 25

    /// Gathers a failed build's facts from Jenkins (AI-02), in the order of an investigation: the build and its failed
    /// stages from the check; the failed tests, the detail's when it has them, else the test report; the console log,
    /// narrowed to its error markers (``FailureLog``); the commits since the last green build. The requests go at once.
    /// Only the log is needed: without the tests or the commits the facts say so.
    ///
    /// - Parameters:
    ///   - build: the failed build
    ///   - failedTests: the failed tests when the detail has them; `nil` reads them
    ///   - flakyHints: what the job's recent builds say of the failed stages, when the detail has it
    ///   - client: the Jenkins client of the build's project
    /// - Returns: the facts
    public static func gather(
        _ build: Build, failedTests: [FailedTest]?, flakyHints: [FlakyHint] = [], client: JenkinsClient
    ) async throws -> BuildFailureFacts {
        async let log = client.failureLog(job: build.job, number: build.number)
        async let changes = try? client.changesSinceLastGreen(job: build.job, number: build.number)
        async let read = failedTests == nil ? (try? client.failedTests(job: build.job, number: build.number)) : nil
        let narrowed: FailureLog
        do {
            narrowed = try await log
        } catch let error as JenkinsError {
            throw AIGatherError("Couldn't read the console log: \(error.problem.message)")
        }
        let found = await changes
        let readTests = await read
        let tests = failedTests ?? readTests ?? []
        return BuildFailureFacts(
            title: build.title ?? build.label, job: build.label, number: build.number,
            result: build.result?.rawValue ?? "FAILURE", failedStages: build.failedStages ?? [], testCounts: build.testCounts,
            failedTests: tests, changes: found?.changes ?? [], lastGreen: found?.lastGreen, log: narrowed,
            flakyHints: flakyHints)
    }
}

extension ClaudePrompt {
    /// the system prompt of "Why Did It Fail?": the method of an investigation, and the answer's parts
    static let explainBuildInstructions = """
        You investigate a failed CI build for the developer who owns it. Answer only from the facts given: the build \
        and its failed stages, the failed tests with their messages, the log lines with error markers (with their line \
        numbers and stage), the end of the log, the stages' recent history, and the commits since the last green build.
        Method: find the first error that explains the failure; later errors, the build tool's summary and its final \
        failure line usually follow from it. Judge it: "real" when the code or a change explains it (a compiler error, a \
        failed assertion, an exception in changed code); "flaky" when it looks like timing, ordering or an unrelated \
        test, or the history shows it failing before or passing on the same commit; "infrastructure" when the machine, \
        network, agent, a registry or a service failed, or a step timed out with nothing in the code to blame; \
        "unclear" when the facts don't tell. A failure with no failed test may come from a log check or a teardown, not \
        a test. Name as suspects only commits whose message fits the failing code; none for flaky or infrastructure.
        Be brief. "headline": the diagnosis, at most 12 words. "failedAt": the stage and the test or step, in a few \
        words. "cause": at most three short sentences. "evidence": 1 to 5 lines copied character for character from \
        the log excerpts or the failed tests, nothing added or explained, the most telling first. "suspects": each \
        commit's hash as given, its author, its message, and why in one short sentence. "nextStep": the one thing to \
        do next, in one or two sentences.
        """

    /// the answer's shape of "Why Did It Fail?", with the limits the answer keeps best when the schema says them
    static let explainBuildSchema = """
        {"type":"object","properties":{"headline":{"type":"string","description":"at most 12 words"},\
        "verdict":{"type":"string","enum":["real","flaky","infrastructure","unclear"]},\
        "failedAt":{"type":"string","description":"the stage and the test or step, a few words"},\
        "cause":{"type":"string","description":"at most three short sentences"},\
        "evidence":{"type":"array","items":{"type":"string","description":"one line of the log excerpts or of a \
        failed test's message, copied exactly, without its line number or any comment"}},\
        "suspects":{"type":"array","items":{"type":"object","properties":{"commit":{"type":"string"},\
        "author":{"type":"string"},"message":{"type":"string"},"why":{"type":"string","description":"one short sentence"}},\
        "required":["commit","author","message","why"]}},\
        "nextStep":{"type":"string","description":"one or two sentences"}},\
        "required":["headline","verdict","failedAt","cause","evidence","suspects","nextStep"]}
        """

    /// Returns the prompt of "Why Did It Fail?" (AI-02), its parts in the order of an investigation: the build with
    /// its failed stages, where in the log they start and first show an error, and their history; the failed tests;
    /// the log's marked lines with their line numbers, then its end; the suspect commits.
    ///
    /// - Parameter facts: the failed build's facts
    /// - Returns: the prompt, not redacted yet
    public static func explainBuild(_ facts: BuildFailureFacts) -> ClaudePrompt {
        var lines = ["A Jenkins build failed. Find the root cause.", ""]

        lines.append("# Build")
        lines.append("\(facts.job) #\(facts.number) \"\(facts.title)\", result \(facts.result)")
        if !facts.failedStages.isEmpty {
            let first = facts.log.firstMarkedLine(inStages: facts.failedStages)
            let stages = facts.failedStages.map { stage in
                var places: [String] = []
                if let start = facts.log.stageStarts[stage] {
                    places.append("starts at log line \(start)")
                }
                if let line = first[stage] {
                    places.append("first error marker at line \(line)")
                }
                return places.isEmpty ? stage : "\(stage) (\(places.joined(separator: ", ")))"
            }
            lines.append("Failed stages: \(stages.joined(separator: "; "))")
        }
        if let counts = facts.testCounts {
            lines.append("Tests: \(counts.failed) of \(counts.total) failed")
        }
        for hint in facts.flakyHints {
            switch hint {
            case .passedOnSameCommit(let stage, let build):
                lines.append("History: stage \"\(stage)\" passed in build #\(build) of the same commit")
            case .failedBefore(let stage, let failed, let of):
                lines.append("History: stage \"\(stage)\" failed in \(failed) of the last \(of) builds")
            }
        }

        lines.append("")
        lines.append(facts.failedTests.isEmpty ? "# Failed tests: none reported" : "# Failed tests (\(facts.failedTests.count))")
        for test in facts.failedTests.prefix(BuildFailureFacts.listedTests) {
            let name = test.className.isEmpty ? test.name : "\(test.className).\(test.name)"
            var notes: [String] = []
            if test.status == .regression {
                notes.append("regression: passed in the build before")
            } else if let age = test.age, age > 1 {
                notes.append("failing for \(age) builds in a row")
            }
            let note = notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"
            let message = test.message.map { ": " + $0.replacingOccurrences(of: "\n", with: " / ") } ?? ""
            lines.append("- \(name)\(note)\(message)")
        }
        if facts.failedTests.count > BuildFailureFacts.listedTests {
            lines.append("- and \(facts.failedTests.count - BuildFailureFacts.listedTests) more")
        }

        lines.append("")
        let log = facts.log
        if log.excerpts.isEmpty {
            lines.append("# Error markers in the log: none found in \(log.lineCount) lines")
        } else {
            var header = "# Error markers in the log (\(log.lineCount) lines, \(log.markedCount) distinct marked"
            header += log.leftOut > 0 ? ", \(log.leftOut) left out)" : ")"
            lines.append(header)
            lines.append("Each excerpt: its marked lines with \">\", the others are context.")
            let width = String(log.excerpts.last?.lastLine ?? 0).count
            for excerpt in log.excerpts {
                var title = "## line \(excerpt.marked.map(String.init).joined(separator: ", "))"
                if let stage = excerpt.stage {
                    title += ", stage \"\(stage)\""
                }
                title += ", " + excerpt.kinds.map(\.title).joined(separator: ", ")
                if excerpt.repeats > 1 {
                    title += ", seen \(excerpt.repeats) times"
                }
                lines.append(title)
                // Jenkins's own lines tell nothing: the numbers keep the places.
                for (offset, line) in excerpt.lines.enumerated() where !line.hasPrefix("[Pipeline] ") {
                    let number = excerpt.firstLine + offset
                    let mark = excerpt.marked.contains(number) ? ">" : " "
                    let padded = String(repeating: " ", count: max(0, width - String(number).count)) + String(number)
                    lines.append("\(mark)\(padded) | \(line)")
                }
            }
        }
        lines.append("")
        lines.append("# End of the log")
        let end = log.tail.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(end.isEmpty ? (log.excerpts.isEmpty ? "(empty)" : "(the excerpts above reach the end)") : end)

        lines.append("")
        if let green = facts.lastGreen {
            lines.append(facts.changes.isEmpty
                ? "# Suspect commits: none since the last green build (#\(green))"
                : "# Suspect commits: since the last green build (#\(green)), newest first")
        } else {
            lines.append(facts.changes.isEmpty
                ? "# Suspect commits: none known (no green build in the job's recent history)"
                : "# Suspect commits: the recent builds' (no green build in the job's recent history), newest first")
        }
        for change in facts.changes.prefix(BuildFailureFacts.listedChanges) {
            lines.append("- \(change.commit.prefix(10)) #\(change.build) \(change.author): \(head(change.message, characters: 200))")
        }
        if facts.changes.count > BuildFailureFacts.listedChanges {
            lines.append("- and \(facts.changes.count - BuildFailureFacts.listedChanges) more")
        }
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
