import Foundation
import Testing

@testable import MenubarCore

/// The build's console log (PIPE-12): the parsing of its bytes, the client's request, and the loader's pages against a
/// made-up log in memory that answers like Jenkins.
@Suite("ConsoleLog")
struct ConsoleLogTests {
    // MARK: Parsing

    @Test(
        "PIPE-12 renders ANSI colors as runs and takes the other escapes out",
        arguments: [
            ("\u{1B}[31mred\u{1B}[0m plain", "red plain", [ConsoleLogRun(location: 0, length: 3, style: .init(foreground: .indexed(1)))]),
            ("\u{1B}[1;38;5;208mX\u{1B}[m", "X", [ConsoleLogRun(location: 0, length: 1, style: .init(foreground: .indexed(208), traits: .bold))]),
            ("\u{1B}[38;2;10;20;30mY\u{1B}[39m", "Y", [ConsoleLogRun(location: 0, length: 1, style: .init(foreground: .rgb(10, 20, 30)))]),
            ("a\u{1B}[92;41mb", "ab", [ConsoleLogRun(location: 1, length: 1, style: .init(foreground: .indexed(10), background: .indexed(1)))]),
            ("\u{1B}[2K\u{1B}[1Gtext\u{1B}]0;title\u{07}more\u{1B}]8;;https://example.com\u{1B}\\", "textmore", []),
            ("a\u{07}b\u{00}c\td\u{1B}(B", "abc\td", []),
            ("🚀\u{1B}[33mx\u{1B}[0m", "🚀x", [ConsoleLogRun(location: 2, length: 1, style: .init(foreground: .indexed(3)))]),
            ("\u{1B}[1mbold\u{1B}[22m \u{1B}[4mline\u{1B}[24m", "bold line", [
                ConsoleLogRun(location: 0, length: 4, style: .init(traits: .bold)),
                ConsoleLogRun(location: 5, length: 4, style: .init(traits: .underline)),
            ]),
        ])
    func ansi(input: String, text: String, runs: [ConsoleLogRun]) {
        let slice = ConsoleLogParser.parse(Data(input.utf8))
        #expect(slice.text == text)
        #expect(slice.runs == runs)
        #expect(slice.utf16Count == slice.text.utf16.count)
    }

    @Test(
        "PIPE-12 takes Jenkins's hidden console notes out",
        arguments: [
            ("a\u{1B}[8mha:////4MzQ2Ym+/=\u{1B}[0mb\n", "ab\n"),
            ("\u{1B}[8mha:////AAAA\u{1B}[0m[Pipeline] sh\n", "[Pipeline] sh\n"),
            // A note without its end, as at a page's cut: the rest of its line goes.
            ("x\u{1B}[8mha:AAAA\nnext", "x\nnext"),
            // Concealed text that isn't a note stays.
            ("\u{1B}[8msecret\u{1B}[0m", "secret"),
        ])
    func consoleNotes(input: String, text: String) {
        #expect(ConsoleLogParser.parse(Data(input.utf8)).text == text)
    }

    @Test(
        "PIPE-12 a lone carriage return starts the line over, CRLF ends it",
        arguments: [
            ("10%\r50%\r100%\n", "100%\n"),
            ("a\r\nb", "a\nb"),
            ("a\r\r\nb\r", "a\nb"),
            ("\u{1B}[32m10%\r\u{1B}[32m99%\u{1B}[0m\n", "99%\n"),
        ])
    func carriageReturns(input: String, text: String) {
        let slice = ConsoleLogParser.parse(Data(input.utf8))
        #expect(slice.text == text)
        #expect(slice.runs.allSatisfy { $0.location + $0.length <= slice.utf16Count })
    }

    @Test("PIPE-12 lines, their starts in UTF-16 and the style carried over the lines")
    func lines() {
        let slice = ConsoleLogParser.parse(Data("Grüße 🚀\n\u{1B}[31mred\nstill red\u{1B}[0m\nlast".utf8))
        #expect(slice.lineCount == 4)
        #expect(slice.lineStarts == [0, 9, 13, 23])
        #expect(slice.runs.map(\.location) == [9, 13])
        #expect(slice.endStyle == .plain)
        let open = ConsoleLogParser.parse(Data("\u{1B}[31mopen\n".utf8))
        #expect(open.endStyle == ConsoleLogStyle(foreground: .indexed(1)))
        #expect(ConsoleLogParser.parse(Data("after\n".utf8), style: open.endStyle).runs.first?.style.foreground == .indexed(1))
    }

    @Test(
        "PIPE-12 finds the error, warning, success and pipeline lines",
        arguments: [
            ("[Pipeline] sh", ConsoleLogLineKind.pipeline),
            ("12:00:01  [Pipeline] { (Build)", .pipeline),
            ("[Pipeline] error", .pipeline),
            ("[ERROR] Failed to execute goal", .error),
            ("[INFO] BUILD FAILURE", .error),
            ("Finished: FAILURE", .error),
            ("> Task :app:test FAILED", .error),
            ("error: cannot find symbol", .error),
            ("src/main.c:3: Error: bad", .error),
            ("npm ERR! code 1", .error),
            ("java.lang.NullPointerException", .error),
            ("Caused by: java.io.IOException: boom", .error),
            ("SEVERE: the agent went away", .error),
            ("[WARNING] deprecated API", .warning),
            ("warning: unused variable", .warning),
            ("Finished: UNSTABLE", .warning),
            ("Finished: ABORTED", .warning),
            ("[INFO] BUILD SUCCESS", .success),
            ("Tests run: 5, Failures: 0, Errors: 0, Skipped: 0", .plain),
            ("0 errors, 2 warnings", .plain),
            ("-Werror is on", .plain),
            ("ErrorProne checks passed", .plain),
            ("an ExceptionHandler was added", .plain),
            ("Compiling 12 source files", .plain),
        ])
    func lineKinds(line: String, kind: ConsoleLogLineKind) {
        #expect(ConsoleLogParser.parse(Data(line.utf8)).kinds == [kind])
    }

    @Test("PIPE-12 blocks end at line ends, also when the size falls inside a character")
    func blocks() {
        let data = Data(String(repeating: "Grüße aus Zürich 🚀 ✓\n", count: 50).utf8)
        for size in [1, 7, 23, 64, 1000] {
            let slices = ConsoleLogParser.slices(of: data, blockSize: size)
            #expect(slices.map(\.text).joined() == ConsoleLogParser.parse(data).text)
            #expect(slices.allSatisfy { $0.text.hasSuffix("\n") })
        }
        // A character cut by a page's end becomes U+FFFD, and the counts stay right.
        let cut = ConsoleLogParser.parse(Data("ok 🚀".utf8).prefix(5))
        #expect(cut.text == "ok \u{FFFD}")
        #expect(cut.utf16Count == cut.text.utf16.count)
    }

    @Test("PIPE-12 finds where an earlier page runs into the next one")
    func alignment() {
        let answer = Data("tail of a line\nline A\nline B\nline C\nline D\nline".utf8)
        let skip = ConsoleLogLoader.firstLineEnd(in: answer)
        #expect(skip == 15)
        #expect(ConsoleLogLoader.alignment(of: answer, from: skip, with: Data("line C\nline D\n".utf8), overlap: 10) == 29)
        // The overlap must be there whole: a head the answer doesn't reach far enough for isn't found.
        #expect(ConsoleLogLoader.alignment(of: answer, from: skip, with: Data("line D\nline E\n".utf8), overlap: 14) == nil)
        // Repeated lines: the first start where the answer goes on as the head does, the longest overlap.
        let repeated = Data("x\n}\n}\n}\nend\n".utf8)
        #expect(ConsoleLogLoader.alignment(of: repeated, from: 2, with: Data("}\n}\nend\n".utf8), overlap: 64) == 4)
        #expect(ConsoleLogLoader.firstLineEnd(in: Data("no break".utf8)) == 8)
    }

    // MARK: The client

    @Test("PIPE-12 reads progressiveText from an offset with a body limit, and keeps the text out of the captured requests")
    func client() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        let path = "/jenkins/job/team/job/MR-1/12/logText/progressiveText"
        stub.answer(path: path, headers: ["X-Text-Size": "4096", "X-More-Data": "true"], body: "SECRET-LOG-LINE\n" + String(repeating: "x", count: 200))
        let log = ActivityLog(folder: folder.file("logs"))
        let capture = RequestCapture(folder: folder.file("requests"))
        let recorder = RequestRecorder(wrapping: stub, log: log, capture: capture)
        let project = Project(id: .main, team: TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/jenkins/job/team", gitLabURL: "https://gitlab.example.com",
            gitLabProject: "team/product"))
        let client = try JenkinsClient.make(project: project, token: "dG9rZW4=", transport: recorder).get()

        let chunk = try await client.consoleLog(job: "MR-1", number: 12, from: 1024, limit: 100)

        #expect(chunk.start == 1024)
        #expect(chunk.size == 4096)
        #expect(chunk.hasMore)
        #expect(chunk.isCut)
        #expect(chunk.body.count == 100)
        let request = try #require(stub.requests.first)
        #expect(request.url.query == "start=1024")
        #expect(request.bodyLimit == 100)
        #expect(!request.keepsBody)
        #expect(!request.url.absoluteString.contains("dG9rZW4="))
        let kept = try FileManager.default.contentsOfDirectory(at: folder.file("requests"), includingPropertiesForKeys: nil)
        #expect(!kept.isEmpty)
        for file in kept {
            #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("SECRET-LOG-LINE"))
        }
        #expect(await log.entries().allSatisfy { !$0.message.contains("SECRET-LOG-LINE") })

        // Finished: no X-More-Data; a body under the limit isn't cut.
        stub.answer(path: path, headers: ["X-Text-Size": "10"], body: "done\n")
        let last = try await client.consoleLog(job: "MR-1", number: 12, from: 5, limit: nil)
        #expect(!last.hasMore)
        #expect(!last.isCut)
        #expect(last.size == 10)
    }

    // MARK: The loader

    /// Small pages, so a made-up log of a few hundred lines takes many.
    private static func limits(maxBytes: Int = 1 << 30) -> ConsoleLogLimits {
        ConsoleLogLimits(probe: 256, page: 2000, block: 700, maxBytes: maxBytes, maxLines: 1_000_000, overlap: 200, slack: 1500)
    }

    /// The text the whole log shows, read at once.
    private static func expected(_ stored: Data) -> String {
        ConsoleLogParser.parse(ConsoleLogFake.stripNotes(stored)).text
    }

    @MainActor
    private static func text(_ loader: ConsoleLogLoader) -> String {
        loader.blocks.map(\.slice.text).joined()
    }

    @Test("PIPE-12 a short log loads whole in one read")
    @MainActor
    func shortLog() async {
        let fake = ConsoleLogFake(stored: Data("\u{1B}[8mha:AAAA\u{1B}[0m[Pipeline] sh\nERROR: boom\nFinished: FAILURE".utf8))
        let loader = ConsoleLogLoader(source: fake.source, limits: Self.limits())

        await loader.open()

        #expect(loader.phase == .loaded)
        #expect(Self.text(loader) == "[Pipeline] sh\nERROR: boom\nFinished: FAILURE")
        #expect(loader.linesBefore == 0)
        #expect(!loader.hasEarlier)
        #expect(!loader.hasLater)
        #expect(loader.isFinished)
        #expect(loader.errorCount == 2)
        #expect(await fake.reads.count == 1)
    }

    @Test("PIPE-12 reads the tail first, then earlier pages, lined up although the notes make the text shorter than the offsets")
    @MainActor
    func tailThenEarlier() async throws {
        let stored = ConsoleLogFake.pipelineLog(lines: 400)
        let fake = ConsoleLogFake(stored: stored)
        let loader = ConsoleLogLoader(source: fake.source, limits: Self.limits())
        let expected = Self.expected(stored)

        await loader.open()

        #expect(loader.phase == .loaded)
        #expect(loader.hasEarlier)
        #expect(loader.linesBefore == nil)
        #expect(Self.text(loader).hasSuffix("Finished: FAILURE\n"))
        #expect(expected.hasSuffix(Self.text(loader)))
        let reads = await fake.reads
        #expect(reads.map { $0.start } == [0, Int64(stored.count - 2000)])
        #expect(reads.map { $0.limit } == [256, nil])

        var pages = 0
        while loader.hasEarlier, pages < 200 {
            await loader.loadEarlier()
            #expect(loader.pageProblem == nil)
            #expect(expected.hasSuffix(Self.text(loader)))
            pages += 1
        }
        #expect(Self.text(loader) == expected)
        #expect(loader.linesBefore == 0)
        #expect(loader.lineCount == ConsoleLogParser.parse(ConsoleLogFake.stripNotes(stored)).lineCount)
        // Every earlier page read only so far, never to the end.
        #expect(await fake.reads.dropFirst(2).allSatisfy { $0.limit != nil })
    }

    @Test("PIPE-12 pages that start inside a UTF-8 character or a note line up all the same")
    @MainActor
    func cutsInsideCharacters() async {
        var text = ""
        for index in 0..<300 {
            text += "\u{1B}[8mha:////QUJD\(index)\u{1B}[0mZeile \(index): Grüße aus Zürich 🚀 ✓ ünïcödé\n"
        }
        let stored = Data(text.utf8)
        for page in [997, 1499, 2003] {
            let fake = ConsoleLogFake(stored: stored)
            let limits = ConsoleLogLimits(probe: 100, page: page, block: 333, maxBytes: 1 << 30, maxLines: 1 << 20, overlap: 120, slack: 900)
            let loader = ConsoleLogLoader(source: fake.source, limits: limits)
            await loader.open()
            while loader.hasEarlier, loader.pageProblem == nil {
                await loader.loadEarlier()
            }
            #expect(loader.pageProblem == nil)
            #expect(Self.text(loader) == Self.expected(stored))
            #expect(!Self.text(loader).contains("\u{FFFD}"))
        }
    }

    @Test("PIPE-12 keeps the memory capped, dropping the farthest pages, and reads them again the same")
    @MainActor
    func memoryCap() async {
        let stored = ConsoleLogFake.pipelineLog(lines: 400)
        let fake = ConsoleLogFake(stored: stored)
        let loader = ConsoleLogLoader(source: fake.source, limits: Self.limits(maxBytes: 5000))
        let expected = Self.expected(stored)

        await loader.open()
        while loader.hasEarlier, loader.pageProblem == nil {
            await loader.loadEarlier()
            #expect(loader.loadedBytes <= 5000 + 2000)
        }
        #expect(loader.pageProblem == nil)
        #expect(loader.hasLater)
        #expect(loader.linesBefore == 0)
        #expect(expected.hasPrefix(Self.text(loader)))

        let readsBefore = await fake.reads.count
        while loader.hasLater, loader.pageProblem == nil {
            await loader.loadLater()
            #expect(loader.loadedBytes <= 5000 + 2000)
            // Lines dropped above still count, so the numbers stay those of the whole log.
            #expect(loader.linesBefore != nil)
        }
        #expect(loader.pageProblem == nil)
        #expect(loader.hasEarlier)
        #expect(expected.hasSuffix(Self.text(loader)))
        #expect(Self.text(loader).hasSuffix("Finished: FAILURE\n"))
        let total = ConsoleLogParser.parse(ConsoleLogFake.stripNotes(stored)).lineCount
        #expect((loader.linesBefore ?? 0) + loader.lineCount == total)
        // A dropped page is read again up to its own end only.
        #expect(await fake.reads.dropFirst(readsBefore).dropLast().allSatisfy { $0.limit != nil })
    }

    @Test("PIPE-12 follows a running build's end, showing its last line once it ends")
    @MainActor
    func follows() async {
        let fake = ConsoleLogFake(stored: Data("[Pipeline] sh\n+ make\nhalf a li".utf8), isRunning: true)
        let clock = TestClock()
        let loader = ConsoleLogLoader(source: fake.source, limits: Self.limits(), clock: clock)

        await loader.open()
        #expect(Self.text(loader) == "[Pipeline] sh\n+ make\n")
        #expect(!loader.isFinished)

        let follow = Task { await loader.follow(every: .seconds(3)) }
        await clock.waitForSleepers()
        await fake.append(Data("ne\nERROR: make failed\nmore".utf8))
        clock.advance(by: .seconds(3))
        // The follower sleeps again only after its read is parsed and published.
        await clock.waitForSleepers()
        #expect(Self.text(loader) == "[Pipeline] sh\n+ make\nhalf a line\nERROR: make failed\n")
        #expect(loader.errorCount == 1)

        // Once the card closes, nothing more is read.
        follow.cancel()
        await follow.value
        let reads = await fake.reads.count
        clock.advance(by: .seconds(9))
        #expect(await fake.reads.count == reads)

        let again = Task { await loader.follow(every: .seconds(3)) }
        await clock.waitForSleepers()
        await fake.append(Data(" output\nFinished: FAILURE".utf8))
        await fake.finish()
        clock.advance(by: .seconds(3))
        // A complete log ends the following, once its last read is published (`isFinished` is set before the parse).
        await again.value
        #expect(loader.isFinished)
        #expect(Self.text(loader) == "[Pipeline] sh\n+ make\nhalf a line\nERROR: make failed\nmore output\nFinished: FAILURE")
    }

    @Test("PIPE-12 a failed first read shows the reason")
    @MainActor
    func failedRead() async {
        let failing = ConsoleLogSource { _, _ in throw JenkinsError(.rejectedToken(.jenkins)) }
        let loader = ConsoleLogLoader(source: failing, limits: Self.limits())
        await loader.open()
        guard case .failed(let message) = loader.phase else {
            Issue.record("expected a failure, got \(loader.phase)")
            return
        }
        #expect(!message.isEmpty)
        #expect(loader.blocks.isEmpty)
    }

    @Test("PIPE-12 parses a 200,000-line log quickly")
    func timing() {
        let stored = ConsoleLogFake.pipelineLog(lines: 200_000)
        let text = ConsoleLogFake.stripNotes(stored)
        let clock = ContinuousClock()
        var slices: [ConsoleLogSlice] = []
        let elapsed = clock.measure {
            slices = ConsoleLogParser.slices(of: text, blockSize: ConsoleLogLimits.standard.block)
        }
        let lines = slices.reduce(0) { $0 + $1.lineCount }
        print("PIPE-12 timing: \(lines) lines, \(text.count / 1024) KB parsed in \(elapsed)")
        #expect(lines >= 200_000 - 20)
        // About half a second in a debug build (2026-11-03); generous for a busy machine.
        #expect(elapsed < .seconds(5))
    }

    // MARK: Save

    /// A stored log with notes and non-ASCII text, whose pages cut inside characters and notes.
    private static func notesLog(lines: Int) -> Data {
        var text = ""
        for index in 0..<lines {
            text += "\u{1B}[8mha:////QUJD\(index)\u{1B}[0mZeile \(index): Grüße aus Zürich 🚀 ✓ ünïcödé\n"
        }
        return Data(text.utf8)
    }

    private static func tinyLimits(page: Int) -> ConsoleLogLimits {
        ConsoleLogLimits(probe: 100, page: page, block: 333, maxBytes: 1 << 30, maxLines: 1 << 20, overlap: 120, slack: 900)
    }

    @Test(
        "PIPE-12 Save writes the whole log in order, read in pages that line up although the notes shorten the text",
        arguments: [997, 1499, 2003, 5000])
    func saveWholeLog(page: Int) async throws {
        let folder = try TemporaryFolder()
        let stored = Self.notesLog(lines: 300)
        let fake = ConsoleLogFake(stored: stored)
        let file = folder.file("MR-12-7.log")
        let seen = ProgressSeen()

        let result = try await ConsoleLogSaver.save(
            source: fake.source, to: file, limits: Self.tinyLimits(page: page), progress: { seen.add($0) })

        #expect(try Data(contentsOf: file) == ConsoleLogFake.stripNotes(stored))
        #expect(result == ConsoleLogSaveResult(bytes: Int64(ConsoleLogFake.stripNotes(stored).count), isComplete: true))
        // Probe, tail, then pages that stop at their own end; the progress only grows and ends at 1.
        let reads = await fake.reads
        #expect(reads[0].limit == 100)
        #expect(reads[1].limit == nil)
        #expect(reads.dropFirst(2).allSatisfy { $0.limit != nil })
        let fractions = seen.values.map(\.fraction)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)
        // Nothing but the file is left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path()) == ["MR-12-7.log"])
    }

    @Test("PIPE-12 Save of a pipeline log with ANSI colors and progress bars keeps every byte but the notes")
    func savePipelineLog() async throws {
        let folder = try TemporaryFolder()
        let stored = ConsoleLogFake.pipelineLog(lines: 600)
        let fake = ConsoleLogFake(stored: stored)
        let file = folder.file("log.log")

        _ = try await ConsoleLogSaver.save(source: fake.source, to: file, limits: Self.limits())

        #expect(try Data(contentsOf: file) == ConsoleLogFake.stripNotes(stored))
    }

    @Test("PIPE-12 Save of a short log is one read, and of a running build says it is not complete")
    func saveShortAndRunning() async throws {
        let folder = try TemporaryFolder()
        let stored = Data("[Pipeline] sh\nERROR: boom\n".utf8)
        let fake = ConsoleLogFake(stored: stored)
        let result = try await ConsoleLogSaver.save(source: fake.source, to: folder.file("a.log"), limits: Self.limits())
        #expect(result == ConsoleLogSaveResult(bytes: Int64(stored.count), isComplete: true))
        #expect(await fake.reads.count == 1)

        let running = ConsoleLogFake(stored: Self.notesLog(lines: 100), isRunning: true)
        let partial = try await ConsoleLogSaver.save(source: running.source, to: folder.file("b.log"), limits: Self.tinyLimits(page: 1500))
        #expect(!partial.isComplete)
        #expect(try Data(contentsOf: folder.file("b.log")) == ConsoleLogFake.stripNotes(Self.notesLog(lines: 100)))
    }

    @Test("PIPE-12 Save that is cancelled or fails leaves the old file and no half-written one")
    func saveCancelledOrFailed() async throws {
        let folder = try TemporaryFolder()
        let file = folder.file("keep.log")
        try Data("old".utf8).write(to: file)
        let stored = Self.notesLog(lines: 300)

        for failure in [CancellationError() as any Error, JenkinsError(.unreachable(.jenkins))] {
            let fake = ConsoleLogFake(stored: stored)
            let count = ReadCount()
            let source = ConsoleLogSource { start, limit in
                // The probe and the tail read, then the first earlier page fails.
                if count.next() == 3 {
                    throw failure
                }
                return try await fake.source.read(start, limit)
            }
            await #expect(throws: (any Error).self) {
                _ = try await ConsoleLogSaver.save(source: source, to: file, limits: Self.tinyLimits(page: 1500))
            }
            #expect(try Data(contentsOf: file) == Data("old".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path()) == ["keep.log"])
        }
    }

    // MARK: Stages

    @Test(
        "PIPE-12 finds the line that opens a stage, alone or after a branch's prefix, and nothing that only looks like it",
        arguments: [
            ("[Pipeline] stage\n[Pipeline] { (Build)\n[Pipeline] sh\n", "Build", 1 as Int?),
            ("a\n[Build in parallel] [Pipeline] { (Build)\nb\n", "Build", 1),
            ("[Pipeline] { (Build Docs)\n[Pipeline] { (Build)\n", "Build", 1),
            ("echo [Pipeline] { (Build)\n", "Build", nil),
            ("[Pipeline] { (Build)\n[Pipeline] { (Build)\n", "Build", 0),
            ("x\r\n[Pipeline] { (Deploy)\r\nz", "Deploy", 1),
            ("[Pipeline] { (Declarative: Post Actions)", "Declarative: Post Actions", 0),
            ("[Pipeline] { (Tests (unit))\n", "Tests (unit)", 0),
            ("[Pipeline] sh\n", "Build", nil),
        ])
    func stageLine(log: String, stage: String, line: Int?) {
        #expect(ConsoleLogStage.firstLine(of: stage, in: ConsoleLogParser.parse(Data(log.utf8))) == line)
    }

    @Test("PIPE-12 locating a stage reads earlier pages until its first line is found, and says so when it isn't there")
    @MainActor
    func locateStage() async throws {
        let stored = ConsoleLogFake.pipelineLog(lines: 600)
        let fake = ConsoleLogFake(stored: stored)
        let loader = ConsoleLogLoader(source: fake.source, limits: Self.limits())

        // "Checkout" is in the log's first lines, the loader starts at its end.
        let location = try #require(await loader.locate(stage: "Checkout"))
        let block = try #require(loader.blocks.first { $0.id == location.blockID })
        let starts = block.slice.lineStarts
        let text = block.slice.text as NSString
        let end = location.line + 1 < starts.count ? starts[location.line + 1] : text.length
        #expect(text.substring(with: NSRange(location: starts[location.line], length: end - starts[location.line])) == "[Pipeline] { (Checkout)\n")
        #expect(loader.pageProblem == nil)
        #expect(loader.locateLoaded(stage: "Checkout") == location)

        let missing = ConsoleLogLoader(source: ConsoleLogFake(stored: stored).source, limits: Self.limits())
        #expect(await missing.locate(stage: "No Such Stage") == nil)
        #expect(!missing.hasEarlier)
        #expect(missing.pageProblem?.contains("No Such Stage") == true)
    }
}

/// The progress a save reported, from its task.
private final class ProgressSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ConsoleLogSaveProgress] = []

    func add(_ progress: ConsoleLogSaveProgress) {
        lock.withLock { items.append(progress) }
    }

    var values: [ConsoleLogSaveProgress] { lock.withLock { items } }
}

private final class ReadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
