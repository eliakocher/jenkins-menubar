import Foundation
import Testing

@testable import MenubarCore

@Suite("ActivityLog")
struct ActivityLogTests {
    private static let time = Date(timeIntervalSince1970: 1_793_000_000.125)

    @Test("LOG-01 keeps each entry on one line")
    func oneLinePerEntry() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url, now: { Self.time })

        await log.log(.warning, .gitlab, "two\nlines\tand a tab\r\nand CRLF", detail: "detail\n" + String(repeating: "x", count: 600), outcome: .failed("TIME\nOUT"))
        await log.log(.info, .app, "Check now")

        let lines = try folder.read("menubar-monitor.log").split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3 && lines.last == "")
        let entries = await log.entries()
        #expect(entries.map(\.message) == ["two lines and a tab and CRLF", "Check now"])
        #expect(entries[0].detail?.count == 500)
        #expect(entries[0].detail?.hasPrefix("detail x") == true)
        #expect(entries[0].outcome?.description == "failed:TIME OUT")
    }

    @Test("LOG-01 writes the time with its offset, level, source, message, detail, outcome and request id")
    func writesTheFields() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url, now: { Self.time })

        await log.log(.debug, .jenkins, "GET /api/json in 0.01s", detail: "the jobs", outcome: .ok("200"), requestID: "20261028-1")

        let line = try folder.read("menubar-monitor.log")
        #expect(line.contains(#""level":"debug""#))
        #expect(line.contains(#""source":"jenkins""#))
        #expect(line.contains(#""message":"GET /api/json in 0.01s""#))
        #expect(line.contains(#""detail":"the jobs""#))
        #expect(line.contains(#""outcome":"ok:200""#))
        #expect(line.contains(#""request":"20261028-1""#))
        #expect(line.contains(/"time":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.125(Z|[+-]\d\d:\d\d)"/))
        let entry = try #require(await log.entries().first)
        #expect(entry == ActivityEntry(time: Self.time, level: .debug, source: .jenkins, message: "GET /api/json in 0.01s",
                                       detail: "the jobs", outcome: .ok("200"), requestID: "20261028-1"))
    }

    @Test("LOG-01 reads the time back in another time zone")
    func readsAnyOffset() throws {
        let line = #"{"time":"2026-10-28T13:00:00.500+01:00","level":"info","source":"app","message":"m"}"#
        let entries = JSONLines.values(ActivityEntry.self, in: Data(line.utf8), decoder: JSONLines.decoder())
        #expect(entries.first?.time == Date(timeIntervalSince1970: 1_793_188_800.5))
    }

    @Test("LOG-03 starts a new log file above 1 MB and keeps 4 old ones")
    func rotates() async throws {
        #expect(ActivityLog.defaultMaxBytes == 1_048_576)
        #expect(ActivityLog.defaultKeptFiles == 5)
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url, maxBytes: 1000, now: { Self.time })

        for number in 1...200 {
            await log.log(.info, .app, "entry \(number)")
        }

        #expect(folder.contents() == ["menubar-monitor.log"] + (1...4).map { "menubar-monitor.log.\($0)" })
        for url in log.fileURLs.dropFirst() {
            // A file is full once it passes the limit, so it holds at most one entry beyond it.
            #expect((1000...1200).contains(LogFiles.size(of: url)))
        }
        let numbers = await log.entries().map { Int($0.message.dropFirst("entry ".count))! }
        #expect(numbers.last == 200)
        #expect(numbers == Array(numbers[0]...200), "oldest first, without gaps")
        #expect(numbers.count < 200)
        #expect(await log.totalBytes() < 5 * 1200)
    }

    @Test("LOG-01 reads the newest entries first, across the files")
    func recentEntries() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url, maxBytes: 300, now: { Self.time })
        for number in 1...10 {
            await log.log(.info, .app, "entry \(number)")
        }

        #expect(await log.recentEntries(limit: 4).map(\.message) == ["entry 10", "entry 9", "entry 8", "entry 7"])
        #expect(folder.contents().count > 1)
    }

    @Test("LOG-01 skips a line cut short and keeps writing after it")
    func skipsBrokenLines() async throws {
        let folder = try TemporaryFolder()
        try folder.write(#"{"time":"2026-10-28T13:00:00.000+01:00","level":"info","source":"app","message":"before"}"# + "\n" + #"{"time":"2026-1"#, to: "menubar-monitor.log")
        let log = ActivityLog(folder: folder.url, now: { Self.time })

        await log.log(.info, .app, "after")
        await log.log(.info, .app, "next")

        #expect(await log.entries().map(\.message) == ["before", "after", "next"])
    }

    @Test("LOG-04 clear deletes every log file")
    func clears() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url, maxBytes: 300, now: { Self.time })
        for number in 1...10 {
            await log.log(.info, .app, "entry \(number)")
        }

        await log.clear()
        #expect(folder.contents().isEmpty)
        await log.log(.info, .app, "Cleared the logs")
        #expect(await log.entries().map(\.message) == ["Cleared the logs"])
    }
}
