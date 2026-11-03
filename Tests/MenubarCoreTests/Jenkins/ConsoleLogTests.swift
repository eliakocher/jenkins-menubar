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
    func follows() async throws {
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
        try await Self.waitUntil { Self.text(loader).hasSuffix("ERROR: make failed\n") }
        #expect(Self.text(loader) == "[Pipeline] sh\n+ make\nhalf a line\nERROR: make failed\n")
        #expect(loader.errorCount == 1)

        // Once the card closes, nothing more is read.
        await clock.waitForSleepers()
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
        try await Self.waitUntil { loader.isFinished }
        #expect(Self.text(loader) == "[Pipeline] sh\n+ make\nhalf a line\nERROR: make failed\nmore output\nFinished: FAILURE")
        // A complete log ends the following.
        await again.value
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

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("timed out waiting")
    }
}
