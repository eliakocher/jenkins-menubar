import Foundation

/// A failed build's console log narrowed to what explains the failure, for "Why Did It Fail?" (AI-02): the lines with
/// error markers, each with a few lines around it, deduplicated and capped, where the failed stages start, and the
/// log's last lines.
///
/// A log of a hundred thousand lines holds its cause in a handful of them, and not always at its end: a compile error or
/// the first failed test is often far before the summary that ends the log. So the whole log is scanned, and only the
/// marked lines go to Claude, not its last characters.
public struct FailureLog: Hashable, Sendable {
    /// What a marked line tells.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// a compiler's error with its file and line, `COMPILATION ERROR`, `cannot find symbol`
        case compiler
        /// a failed test: a per-test failure marker, a test summary with failures, an assertion
        case testFailure
        /// the machine, the network or the services around the build: out of disk or memory, a lost agent, a refused
        /// connection, a registry that doesn't answer
        case infrastructure
        /// a step or the build that ran out of time
        case timeout
        /// an exception or its `Caused by`, a traceback, a panic
        case exception
        /// the build tool's own verdict: `BUILD FAILURE`, a failed goal or task, a script's exit code
        case buildFailure
        /// any other line that says ERROR
        case error

        /// "compiler error", "test failure"
        public var title: String {
            switch self {
            case .compiler: "compiler error"
            case .testFailure: "test failure"
            case .infrastructure: "infrastructure"
            case .timeout: "timeout"
            case .exception: "exception"
            case .buildFailure: "build failure"
            case .error: "error"
            }
        }
    }

    /// A marked line with the lines around it; overlapping ones are joined.
    public struct Excerpt: Hashable, Sendable {
        /// the first line's number in the log, from 1
        public var firstLine: Int
        /// the lines, without terminal colors, each cut at ``FailureLog/lineCharacters``
        public var lines: [String]
        /// the marked lines' numbers, in order
        public var marked: [Int]
        /// what the marked lines tell, in their order, each once
        public var kinds: [Kind]
        /// the stage the log was in at the first marked line, from the pipeline's `[Pipeline] { (Name)` lines
        public var stage: String?
        /// how often the marked lines appear in the log, themselves included, with numbers and times ignored
        public var repeats: Int

        public init(firstLine: Int, lines: [String], marked: [Int], kinds: [Kind], stage: String? = nil, repeats: Int = 1) {
            self.firstLine = firstLine
            self.lines = lines
            self.marked = marked
            self.kinds = kinds
            self.stage = stage
            self.repeats = repeats
        }

        /// the last line's number
        public var lastLine: Int {
            firstLine + lines.count - 1
        }
    }

    /// the excerpts, in the log's order
    public var excerpts: [Excerpt]
    /// the log's last lines after the last excerpt, without the pipeline's own `[Pipeline]` lines; empty when the
    /// excerpts reach the end
    public var tail: String
    /// the log's length in lines
    public var lineCount: Int
    /// how many distinct marked lines the log has
    public var markedCount: Int
    /// how many distinct marked lines didn't fit
    public var leftOut: Int
    /// where each stage first starts, by its name: the line number
    public var stageStarts: [String: Int]

    public init(
        excerpts: [Excerpt] = [], tail: String = "", lineCount: Int = 0, markedCount: Int = 0, leftOut: Int = 0,
        stageStarts: [String: Int] = [:]
    ) {
        self.excerpts = excerpts
        self.tail = tail
        self.lineCount = lineCount
        self.markedCount = markedCount
        self.leftOut = leftOut
        self.stageStarts = stageStarts
    }

    /// lines kept before a marked line
    public static let linesBefore = 2
    /// lines kept after a marked line: the first frames of a stack trace
    public static let linesAfter = 3
    /// the most excerpts of one kind, so a hundred failed tests leave room for the compiler error
    public static let perKind = 6
    /// the most characters of all excerpts, each line counted with 8 for its number: about 2,500 tokens
    public static let excerptCharacters = 9_000
    /// the longest line kept; a longer one ends with an ellipsis
    public static let lineCharacters = 300
    /// how many of the log's last lines are kept after the excerpts
    public static let tailLines = 30
    /// the most characters of the end of the log next to excerpts
    public static let tailCharacters = 2_500
    /// the most characters of the end of a log without a marked line: the whole budget goes to its end
    public static let bareTailCharacters = 10_000

    /// Returns the first line of each failed stage that a marked line is in, by stage: where in the log the stage fails.
    ///
    /// - Parameter stages: the failed stages
    /// - Returns: the line, for the stages with one
    public func firstMarkedLine(inStages stages: [String]) -> [String: Int] {
        var found: [String: Int] = [:]
        for excerpt in excerpts {
            if let stage = excerpt.stage, stages.contains(stage), found[stage] == nil, let line = excerpt.marked.first {
                found[stage] = line
            }
        }
        return found
    }
}

extension FailureLog {
    /// Narrows a console log to its marked lines (AI-02).
    ///
    /// Each line is checked for the markers of ``Kind``, first the cheap substrings, then the patterns; a stack frame
    /// (`at …`) or one of Jenkins's own `[Pipeline]` lines is never marked. Lines that are the same apart from their
    /// numbers, times and hashes count as one, at their first place, with how often they repeat. When there are more than
    /// fit, at most ``perKind`` of a kind are taken, the kinds in ``Kind``'s order and each kind's earliest first, until
    /// ``excerptCharacters``; the others count as left out. The excerpts keep ``linesBefore`` and ``linesAfter`` lines
    /// around, join where they touch, and come in the log's order.
    ///
    /// - Parameter log: the console log, as Jenkins's `consoleText` gives it
    /// - Returns: the narrowed log
    public static func narrow(_ log: String) -> FailureLog {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.last == "\r" ? line.dropLast() : line
        }
        // A log that ends with a line break doesn't have an empty last line.
        let count = lines.last?.isEmpty == true ? lines.count - 1 : lines.count

        // The stages: a stack of the open blocks, named or not.
        var open: [String?] = []
        var stageAt = [String?](repeating: nil, count: max(count, 0))
        var stageStarts: [String: Int] = [:]
        // The marked lines: each distinct one at its first place, with its repeats.
        var firsts: [(index: Int, kind: Kind)] = []
        var repeats: [String: Int] = [:]
        var firstOfKey: [String: Int] = [:]
        for index in 0..<max(count, 0) {
            let line = lines[index]
            if line.hasPrefix("[Pipeline] ") {
                if line.hasPrefix("[Pipeline] { (") {
                    var name = String(line.dropFirst("[Pipeline] { (".count))
                    if name.hasSuffix(")") {
                        name.removeLast()
                    }
                    if name.hasPrefix("Branch: ") {
                        name = String(name.dropFirst("Branch: ".count))
                    }
                    open.append(name)
                    if stageStarts[name] == nil {
                        stageStarts[name] = index + 1
                    }
                } else if line == "[Pipeline] {" {
                    open.append(nil)
                } else if line == "[Pipeline] }", !open.isEmpty {
                    open.removeLast()
                }
                stageAt[index] = open.last { $0 != nil } ?? nil
                continue
            }
            stageAt[index] = open.last { $0 != nil } ?? nil
            let text = clean(line)
            guard let kind = kind(of: text) else {
                continue
            }
            let key = dedupeKey(text)
            if repeats[key] == nil {
                firsts.append((index, kind))
                firstOfKey[key] = index
            }
            repeats[key, default: 0] += 1
        }
        var repeatsAt: [Int: Int] = [:]
        for (key, index) in firstOfKey {
            repeatsAt[index] = repeats[key]
        }

        // Which marked lines fit: by kind, then earliest.
        let ranked = firsts.enumerated().sorted { one, other in
            let a = Kind.allCases.firstIndex(of: one.element.kind) ?? 0
            let b = Kind.allCases.firstIndex(of: other.element.kind) ?? 0
            return a != b ? a < b : one.offset < other.offset
        }.map(\.element)
        var taken: [(index: Int, kind: Kind)] = []
        var takenPerKind: [Kind: Int] = [:]
        var covered = IndexSet()
        var characters = 0
        for mark in ranked {
            guard takenPerKind[mark.kind, default: 0] < perKind else {
                continue
            }
            let window = max(0, mark.index - linesBefore)...min(count - 1, mark.index + linesAfter)
            // Each line as shown, with room for its number and mark.
            let added = window.filter { !covered.contains($0) }.reduce(0) { $0 + display(lines[$1]).count + 8 }
            guard characters + added <= excerptCharacters else {
                continue
            }
            characters += added
            covered.insert(integersIn: window)
            taken.append(mark)
            takenPerKind[mark.kind, default: 0] += 1
        }

        // The excerpts: the windows joined where they touch, in the log's order.
        var excerpts: [Excerpt] = []
        for mark in taken.sorted(by: { $0.index < $1.index }) {
            let start = max(0, mark.index - linesBefore)
            let end = min(count - 1, mark.index + linesAfter)
            // The last excerpt's lastLine, counted from 1, is the index of the line after it: a window that starts there
            // or before touches it.
            if var last = excerpts.last, start <= last.lastLine {
                let next = last.lastLine
                if end >= next {
                    last.lines += (next...end).map { display(lines[$0]) }
                }
                last.marked.append(mark.index + 1)
                if !last.kinds.contains(mark.kind) {
                    last.kinds.append(mark.kind)
                }
                last.repeats = max(last.repeats, repeatsAt[mark.index] ?? 1)
                excerpts[excerpts.count - 1] = last
            } else {
                excerpts.append(Excerpt(
                    firstLine: start + 1, lines: (start...end).map { display(lines[$0]) }, marked: [mark.index + 1],
                    kinds: [mark.kind], stage: stageAt[mark.index], repeats: repeatsAt[mark.index] ?? 1))
            }
        }

        // The end of the log after the last excerpt, without Jenkins's own lines; longer when nothing is marked.
        let tail: String
        if let last = excerpts.last {
            let from = max(last.lastLine, count - tailLines)
            let end = lines[min(from, count)..<max(count, 0)].filter { !$0.hasPrefix("[Pipeline] ") }.map(display)
            tail = cutFromEnd(end, characters: tailCharacters)
        } else {
            let body = lines.prefix(max(count, 0)).filter { !$0.hasPrefix("[Pipeline] ") }.map(display)
            tail = cutFromEnd(body, characters: bareTailCharacters)
        }
        return FailureLog(
            excerpts: excerpts, tail: tail, lineCount: max(count, 0), markedCount: firsts.count,
            leftOut: firsts.count - taken.count, stageStarts: stageStarts)
    }

    // MARK: - The markers

    /// Returns what a line tells, or `nil` for an ordinary line.
    ///
    /// - Parameter text: the line without terminal colors
    static func kind(of text: Substring) -> Kind? {
        // Most lines have none of these: they skip the patterns.
        guard containsAny(text, triggers) else {
            return nil
        }
        let trimmed = text.drop { $0 == " " || $0 == "\t" }
        // A stack frame is context, never a mark of its own.
        if trimmed.hasPrefix("at ") || trimmed.hasPrefix("... ") {
            return nil
        }
        if containsAny(text, infrastructure) {
            return .infrastructure
        }
        if timeouts.contains(where: { text.localizedStandardContains($0) }) {
            return .timeout
        }
        if containsAny(text, compilerWords) || matches(compilerPatterns, text) {
            return .compiler
        }
        if containsAny(text, testWords) || matches(testPatterns, text) || failingSummary(text) {
            return .testFailure
        }
        if containsAny(text, buildWords) {
            return .buildFailure
        }
        if containsAny(text, exceptionWords) || trimmed.hasPrefix("panic: ") || matches([exceptionName], text) {
            return .exception
        }
        if matches([errorWord], text) {
            return .error
        }
        return nil
    }

    /// Returns whether a line has one of the words, comparing bytes: a log has a hundred thousand lines.
    private static func containsAny(_ text: Substring, _ words: Words) -> Bool {
        var text = text
        return text.withUTF8 { line in
            guard let base = line.baseAddress, !line.isEmpty else {
                return false
            }
            return words.bytes.contains { word in
                word.withUnsafeBytes { needle in
                    memmem(base, line.count, needle.baseAddress, needle.count) != nil
                }
            }
        }
    }

    /// Words to look for, as UTF-8.
    private struct Words: Sendable {
        let bytes: [[UInt8]]

        init(_ words: [String]) {
            bytes = words.map { Array($0.utf8) }
        }
    }

    /// the substrings a marked line has at least one of
    private static let triggers = Words([
        "rror", "RROR", "FAIL", "Fail", "fail", "xception", "Caused by", "imeout", "imed out", "IMEOUT", "No space",
        "refused", "reset", "resolve", "isconnect", "offline", "Killed", "exit code", "Traceback", "<<<", "Tests run:",
        "OutOfMemory", "allocate memory", "Unavailable", "Bad Gateway", "Too Many Requests", "rate limit", "panic: ",
        "Cannot contact", "ChannelClosed", "cannot find symbol", "deadline exceeded", "Assertion", "expected:",
    ])

    private static let infrastructure = Words([
        "No space left on device", "OutOfMemoryError", "Cannot allocate memory", "Connection refused", "Connection reset",
        "reset by peer", "Could not resolve host", "UnknownHostException", "Temporary failure in name resolution",
        "Name or service not known", "Cannot contact ", "was disconnected", "ChannelClosedException",
        "RemovedNodeListener", "went offline", "is offline", "Could not transfer artifact", "Could not resolve dependencies",
        "503 Service Unavailable", "502 Bad Gateway", "429 Too Many Requests", "rate limit exceeded",
        "Error response from daemon", "exit code 137", "Killed", "Read timed out", "Connect timed out",
        "Connection timed out", "SSLHandshakeException",
    ])

    /// matched without regard to case
    private static let timeouts = [
        "timed out", "timeout has been exceeded", "TimeoutException", "due to timeout", "deadline exceeded",
        "exceeded the timeout", "timeout expired",
    ]

    private static let compilerWords = Words(["COMPILATION ERROR", "Compilation failure", "cannot find symbol", "Compilation failed"])

    private static let compilerPatterns = [
        // `Cart.java:[12,5] error`, `Cart.swift:12:5: error:`, `cart.ts(12,5): error TS2345`, `e: Cart.kt:12:5`.
        regex(#"\.(java|kt|kts|scala|groovy|ts|tsx|js|jsx|swift|c|cc|cpp|h|hpp|m|mm|go|rs|cs)(:\[?\d+[,:\]]|\(\d+,\d+\)).*\b(error|ERROR)\b"#),
        regex(#"\[ERROR\] [^ ]+\.(java|kt|scala|groovy):\[\d+"#),
        regex(#"\berror TS\d{3,}"#),
        regex(#"^\s*e: [^ ]+\.kts?:"#),
        regex(#"\bSyntaxError\b"#),
    ]

    private static let testWords = Words([
        "<<< FAILURE", "<<< ERROR", "AssertionError", "AssertionFailedError", "ComparisonFailure", "expected:<",
        "Tests in error", "Failed tests:",
    ])

    private static let testPatterns = [
        // A per-test marker: `Class#method: failed (FAILURE)`.
        regex(#": failed \((FAILURE|ERROR)\)"#),
        regex(#"\bThere (was|were) \d+ (failure|error)s?\b"#),
        // pytest's and jest's per-test lines.
        regex(#"^\s*(\[[^\]]*\]\s*)?(FAILED|FAIL)\s+\S+"#),
        regex(#"(?i)\btests? (failed|failures)\b"#),
        regex(#"> Task :\S*[tT]est\S* FAILED"#),
    ]

    private static let buildWords = Words([
        "BUILD FAILURE", "BUILD FAILED", "Failed to execute goal", "script returned exit code", "returned non-zero exit status",
        "make: ***", "npm ERR!", "FAILURE: Build failed", "Execution failed for task", "Process exited with code",
    ])

    private static let exceptionWords = Words(["Caused by: ", "Exception in thread", "Traceback (most recent call last)"])

    /// `com.example.CartException`, `java.lang.IllegalStateException:`: a qualified exception or error name
    private static let exceptionName = regex(#"\b([a-z_][\w$]*\.)+[A-Z][\w$]*(Exception|Error)\b"#)

    /// ERROR as a word, upper case: `[ERROR]`, `ERROR:`, `… ERROR c.e.Cart -`, or `error:` at a line's start
    private static let errorWord = regex(#"(\bERROR\b|^\s*(\[[^\]]*\]\s*)?error:)"#)

    /// `Tests run: 12, Failures: 1, Errors: 0`, with a failure or an error
    private static let summary = regex(#"Tests run: \d+, Failures: (\d+), Errors: (\d+)"#)

    private static func failingSummary(_ text: Substring) -> Bool {
        let string = String(text)
        guard let match = summary.expression.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let failures = Range(match.range(at: 1), in: string), let errors = Range(match.range(at: 2), in: string)
        else {
            return false
        }
        return string[failures] != "0" || string[errors] != "0"
    }

    private static func matches(_ patterns: [Pattern], _ text: Substring) -> Bool {
        let string = String(text)
        let range = NSRange(string.startIndex..., in: string)
        return patterns.contains { $0.expression.firstMatch(in: string, range: range) != nil }
    }

    // MARK: - Cleaning

    /// Returns a line without terminal colors.
    static func clean(_ line: Substring) -> Substring {
        guard line.utf8.contains(0x1B) else {
            return line
        }
        let string = String(line)
        return Substring(ansi.expression.stringByReplacingMatches(
            in: string, range: NSRange(string.startIndex..., in: string), withTemplate: ""))
    }

    /// Returns a line as an excerpt shows it: without terminal colors, cut at ``lineCharacters``.
    static func display(_ line: Substring) -> String {
        let text = clean(line)
        return text.count > lineCharacters ? String(text.prefix(lineCharacters)) + "…" : String(text)
    }

    /// Returns what makes two marked lines the same: the line without its leading time, its numbers and hashes, and
    /// its spaces squeezed.
    static func dedupeKey(_ text: Substring) -> String {
        let string = String(text)
        let range = NSRange(string.startIndex..., in: string)
        var key = timestamp.expression.stringByReplacingMatches(in: string, range: range, withTemplate: "")
        key = digits.expression.stringByReplacingMatches(in: key, range: NSRange(key.startIndex..., in: key), withTemplate: "#")
        return key.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Returns the last lines that fit in the characters, from a line's start.
    private static func cutFromEnd(_ lines: [String], characters: Int) -> String {
        var kept: [String] = []
        var total = 0
        for line in lines.reversed() {
            guard total + line.count + 1 <= characters else {
                break
            }
            kept.append(line)
            total += line.count + 1
        }
        return kept.reversed().joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private struct Pattern: @unchecked Sendable {
        // NSRegularExpression is immutable and documented as thread-safe.
        let expression: NSRegularExpression
    }

    private static func regex(_ pattern: String) -> Pattern {
        // The patterns are fixed: a broken one is a programming error that the tests catch.
        Pattern(expression: try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]))
    }

    private static let ansi = regex(#"\u001B\[[0-9;?]*[A-Za-z]"#)
    private static let timestamp = regex(#"^\s*\[?\d{4}-\d{2}-\d{2}[T ][\d:.,]+Z?\]?\s*|^\s*\[?\d{2}:\d{2}:\d{2}([.,]\d+)?\]?\s*"#)
    /// numbers and hex hashes of six characters or more
    private static let digits = regex(#"\b[0-9a-f]{6,}\b|\d+"#)
}
