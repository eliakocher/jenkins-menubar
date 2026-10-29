import Foundation
import Testing

@testable import MenubarCore

@Suite("FileStore")
struct FileStoreTests {
    /// Collects the reports of corrupt files.
    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        var all: [String] { lock.withLock { messages } }

        func add(_ message: String) {
            lock.withLock { messages.append(message) }
        }
    }

    private struct Sample: Codable, Equatable, Sendable {
        var name: String
        var when: Date
    }

    @Test("a missing file reads as nothing, without a report")
    func missingFile() throws {
        let folder = try TemporaryFolder()
        let reports = Reports()
        let store = FileStore<Sample>(url: folder.file("sample.json"), report: reports.add)

        #expect(store.load() == nil)
        #expect(reports.all.isEmpty)
        try store.delete()
    }

    @Test("a value round-trips exactly, into a folder created on the first write")
    func roundTrip() throws {
        let folder = try TemporaryFolder()
        let store = FileStore<Sample>(url: folder.file("a/b/sample.json"), report: { _ in })
        let sample = Sample(name: "x", when: Date(timeIntervalSince1970: 1_800_000_000.123_456_7))

        try store.save(sample)
        try store.save(Sample(name: "y", when: sample.when))

        #expect(store.load() == Sample(name: "y", when: sample.when))
        #expect(folder.contents() == ["a/b/sample.json"])
        #expect(try folder.read("a/b/sample.json").contains(#""name" : "y""#))
    }

    @Test("a corrupt file counts as empty, is kept aside and reported once", arguments: [
        "not json", #"{"name": 5}"#, "",
    ])
    func corruptFile(content: String) throws {
        let folder = try TemporaryFolder()
        let reports = Reports()
        let url = try folder.write(content, to: "sample.json")
        let store = FileStore<Sample>(url: url, report: reports.add)

        #expect(store.load() == nil)
        #expect(store.load() == nil)
        #expect(reports.all.count == 1)
        #expect(reports.all.first?.hasPrefix("sample.json could not be read and counts as empty, kept as sample.json.corrupt: ") == true)
        #expect(try folder.read("sample.json.corrupt") == content)

        try store.save(Sample(name: "fresh", when: Date(timeIntervalSince1970: 0)))
        #expect(store.load()?.name == "fresh")
        #expect(folder.contents() == ["sample.json", "sample.json.corrupt"])
    }

    @Test("deleting removes the file")
    func delete() throws {
        let folder = try TemporaryFolder()
        let store = FileStore<Sample>(url: folder.file("sample.json"), report: { _ in })

        try store.save(Sample(name: "x", when: Date()))
        try store.delete()

        #expect(store.load() == nil)
        #expect(folder.contents().isEmpty)
    }
}
