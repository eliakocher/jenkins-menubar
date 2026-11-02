import Foundation
import Testing

@testable import MenubarCore

/// The opened details kept on disk (OD-07): what comes back, the limits and which detail goes first.
@Suite("Detail cache")
struct DetailCacheTests {
    /// A time the tests move forward, so the least recently used is known.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSinceReferenceDate: 800_000_000)

        var now: Date { lock.withLock { value } }

        func tick() {
            lock.withLock { value += 1 }
        }
    }

    @Test("OD-07 a kept detail comes back with its update time, and nothing names the item on disk")
    func roundTrip() throws {
        let folder = try TemporaryFolder()
        let cache = DetailCache(folder: folder.file("details"))
        let updatedAt = Date(timeIntervalSinceReferenceDate: 800_000_000.123)

        cache.save("A description", updatedAt: updatedAt, as: .itemDescription, key: "group/project!16")

        let kept = try #require(cache.load(.itemDescription, key: "group/project!16"))
        #expect(kept.value == "A description")
        #expect(kept.updatedAt == updatedAt)
        #expect(cache.load(.itemDescription, key: "group/project!17") == nil)
        // Another kind with the same key is another detail.
        #expect(cache.load(.workItemDiscussion, key: "group/project!16") == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.file("details").path)
        #expect(names.count == 1)
        #expect(names.allSatisfy { !$0.contains("project") && !$0.contains("!") })
    }

    @Test("OD-07 beyond its limits the least recently used detail goes first, and a load counts as a use")
    func evictsLeastRecentlyUsed() throws {
        let folder = try TemporaryFolder()
        let clock = Clock()
        let cache = DetailCache(folder: folder.file("details"), maxFiles: 2, now: { clock.now })

        cache.save("one", updatedAt: nil, as: .itemDescription, key: "a")
        clock.tick()
        cache.save("two", updatedAt: nil, as: .itemDescription, key: "b")
        clock.tick()
        // Using "a" makes "b" the oldest.
        _ = cache.load(.itemDescription, key: "a")
        clock.tick()
        cache.save("three", updatedAt: nil, as: .itemDescription, key: "c")

        #expect(cache.load(.itemDescription, key: "a")?.value == "one")
        #expect(cache.load(.itemDescription, key: "b") == nil)
        #expect(cache.load(.itemDescription, key: "c")?.value == "three")

        // The byte limit too, also for a cache made after a relaunch.
        let small = DetailCache(folder: folder.file("details"), maxBytes: 1, now: { clock.now })
        clock.tick()
        small.save("four", updatedAt: nil, as: .itemDescription, key: "d")
        // Nothing fits in one byte: every file goes, the new one too.
        #expect(small.totalBytes() == 0)
        #expect(small.load(.itemDescription, key: "a") == nil)
    }

    @Test("OD-07 clearing the cache forgets every detail")
    func clears() throws {
        let folder = try TemporaryFolder()
        let cache = DetailCache(folder: folder.file("details"))
        cache.save("one", updatedAt: nil, as: .itemDescription, key: "a")
        cache.clear()
        #expect(cache.load(.itemDescription, key: "a") == nil)
        #expect(cache.totalBytes() == 0)
    }
}
