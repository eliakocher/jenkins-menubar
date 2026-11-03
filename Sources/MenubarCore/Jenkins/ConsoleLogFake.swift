#if DEBUG
import Foundation

/// A console log in memory that answers like Jenkins's `progressiveText`, for the tests and the gallery (PIPE-12):
/// offsets count the stored bytes with their hidden notes, the text sent has the whole notes taken out, a start past the
/// end starts over at 0, and `hasMore` holds while the build "runs". Debug builds only.
public actor ConsoleLogFake {
    /// the stored log, notes and all
    public private(set) var stored: Data
    public private(set) var isRunning: Bool
    /// every read, oldest first: its start and limit
    public private(set) var reads: [(start: Int64, limit: Int?)] = []

    public init(stored: Data, isRunning: Bool = false) {
        self.stored = stored
        self.isRunning = isRunning
    }

    /// The build writes more.
    public func append(_ data: Data) {
        stored += data
    }

    /// The build ends.
    public func finish() {
        isRunning = false
    }

    /// the source that reads this log
    public nonisolated var source: ConsoleLogSource {
        ConsoleLogSource { [self] start, limit in
            await read(from: start, limit: limit)
        }
    }

    public func read(from start: Int64, limit: Int?) -> ConsoleLogChunk {
        reads.append((start, limit))
        return Self.chunk(of: stored, from: start, limit: limit, hasMore: isRunning)
    }

    /// Returns what Jenkins answers for a stored log: the text from `start` without the notes, at most `limit` bytes.
    public static func chunk(of stored: Data, from start: Int64, limit: Int?, hasMore: Bool) -> ConsoleLogChunk {
        let from = start > Int64(stored.count) ? 0 : Int(start)
        let text = stripNotes(stored.subdata(in: from..<stored.count))
        let body = limit.map { text.prefix($0) } ?? text
        return ConsoleLogChunk(
            start: Int64(from), body: Data(body), size: Int64(stored.count), hasMore: hasMore,
            isCut: limit.map { text.count > $0 } ?? false)
    }

    /// Takes out the whole notes, as Jenkins's `PlainTextConsoleOutputStream` does; a note cut by the start stays.
    public static func stripNotes(_ data: Data) -> Data {
        let preamble = Data([0x1B, 0x5B, 0x38, 0x6D, 0x68, 0x61, 0x3A])
        let postamble = Data([0x1B, 0x5B, 0x30, 0x6D])
        var result = Data()
        result.reserveCapacity(data.count)
        var index = data.startIndex
        while let found = data.range(of: preamble, in: index..<data.endIndex) {
            guard let close = data.range(of: postamble, in: found.upperBound..<data.endIndex) else { break }
            result += data[index..<found.lowerBound]
            index = close.upperBound
        }
        result += data[index...]
        return result
    }

    // MARK: A made-up log

    /// Returns a made-up pipeline log: `[Pipeline]` steps with their hidden notes, a Maven build in ANSI colors,
    /// warnings, a failed test with its stack trace, a progress bar redrawn with `\r`, umlauts and an emoji, and
    /// `Finished: FAILURE` at the end. The same lines for the same count.
    ///
    /// - Parameter lines: about how many lines
    /// - Returns: the stored bytes, notes and all
    public static func pipelineLog(lines: Int) -> Data {
        var text = ""
        text.reserveCapacity(lines * 90)
        func note(_ seed: Int) -> String {
            "\u{1B}[8mha:////4Mz\(String(seed, radix: 36))Q2YmVhZmZlY3RlZEFubm90YXRpb24AAAA=\u{1B}[0m"
        }
        let modules = ["core", "api", "web", "search-index", "notifications", "billing-adapter", "settings-store"]
        var count = 0
        func add(_ line: String) {
            text += line
            text += "\n"
            count += 1
        }
        add("Started by GitLab push by Sam Lee")
        add("Obtained Jenkinsfile from git https://gitlab.example.com/group/project.git")
        add("\(note(1))[Pipeline] Start of Pipeline")
        add("\(note(2))[Pipeline] node")
        add("Running on build-agent-07 in /var/lib/jenkins/workspace/project_MR-12")
        add("\(note(3))[Pipeline] {")
        add("\(note(4))[Pipeline] stage")
        add("\(note(5))[Pipeline] { (Checkout)")
        add(" > git fetch --no-tags --force --progress -- https://gitlab.example.com/group/project.git")
        add("Receiving objects:  12% (1200/10000)\rReceiving objects:  64% (6400/10000)\rReceiving objects: 100% (10000/10000), done.")
        add("Checking out Revision 3f9c2e1d7a (refs/remotes/origin/MR-12) · Grüße aus Zürich 🚀")
        var round = 0
        while count < lines - 12 {
            round += 1
            let module = modules[round % modules.count]
            add("\(note(round * 10))[Pipeline] sh")
            add("+ ./mvnw -B -pl \(module) verify")
            add("\u{1B}[1;34m[INFO]\u{1B}[0m Building \(module) 2026.\(round % 12).0-SNAPSHOT [\(round % 40 + 1)/40]")
            for file in 0..<6 {
                add("\u{1B}[1;34m[INFO]\u{1B}[0m Compiling \(file + round % 9 + 1) source files to /workspace/\(module)/target/classes")
            }
            if round % 5 == 0 {
                add("\u{1B}[1;33m[WARNING]\u{1B}[0m /workspace/\(module)/src/main/java/Store.java:[\(round % 300 + 12),8] deprecated API")
            }
            add("\u{1B}[1;34m[INFO]\u{1B}[0m Tests run: \(round % 90 + 10), Failures: 0, Errors: 0, Skipped: \(round % 3)")
            if round % 97 == 0 {
                add("\u{1B}[1;31m[ERROR]\u{1B}[0m Tests run: 4, Failures: 1, Errors: 0, Skipped: 0 <<< FAILURE! - in SessionStoreTest")
                add("java.lang.AssertionError: expected:<200> but was:<503>")
                add("\tat org.junit.Assert.fail(Assert.java:89)")
                add("\tat com.example.session.SessionStoreTest.refreshesToken(SessionStoreTest.java:\(round % 200 + 40))")
                add("Caused by: java.net.SocketTimeoutException: Read timed out")
            }
            add("\(note(round * 10 + 1))[Pipeline] }")
        }
        add("\(note(90))[Pipeline] // stage")
        add("\u{1B}[1;31m[ERROR]\u{1B}[0m Failed to execute goal on project billing-adapter: There are test failures.")
        add("\u{1B}[1;34m[INFO]\u{1B}[0m \u{1B}[1;31mBUILD FAILURE\u{1B}[0m")
        add("\(note(91))[Pipeline] }")
        add("\(note(92))[Pipeline] // node")
        add("\(note(93))[Pipeline] End of Pipeline")
        add("ERROR: script returned exit code 1")
        add("Finished: FAILURE")
        return Data(text.utf8)
    }
}
#endif
