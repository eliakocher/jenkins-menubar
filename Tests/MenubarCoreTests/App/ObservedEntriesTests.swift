import Observation
import Testing

@testable import MenubarCore

@Suite("ObservedEntries")
@MainActor
struct ObservedEntriesTests {
    @Test("WIN-02 a detail store's entry wakes only who read it, also before it came, and all of them for every entry")
    func observesPerKey() {
        let entries = ObservedEntries<String, Int>()
        entries["a"] = 1
        let changed = Changes()

        withObservationTracking { _ = entries["a"] } onChange: { changed.note("a") }
        // A key without an entry yet is observed too.
        withObservationTracking { _ = entries["c"] } onChange: { changed.note("c") }
        withObservationTracking { _ = entries.all } onChange: { changed.note("all") }

        entries["b"] = 2
        #expect(changed.keys == ["all"])
        entries["a"] = 3
        entries["c"] = 4
        #expect(changed.keys == ["all", "a", "c"])
        #expect(entries.all == ["a": 3, "b": 2, "c": 4])
        #expect(Set(entries.keys) == ["a", "b", "c"])

        entries.removeAll()
        #expect(entries["a"] == nil)
        #expect(entries.all.isEmpty)
    }
}

@MainActor
private final class Changes: @unchecked Sendable {
    private(set) var keys: [String] = []

    nonisolated func note(_ key: String) {
        MainActor.assumeIsolated { keys.append(key) }
    }
}
