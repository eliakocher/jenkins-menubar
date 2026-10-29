import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

/// The Activity section's own rules beyond `ActivityStore`: what the inspector shows for a multiple selection, which
/// selected entries survive a reload, what Copy copies, the subtitle and the pills' colors.
@Suite("ActivityView")
@MainActor
struct ActivityViewTests {
    /// 2026-10-28 12:30:00 UTC
    private nonisolated static let now = Date(timeIntervalSince1970: 1_793_190_600)

    /// three entries a minute apart, newest first, as `ActivityStore.items` holds them
    private static let items: [ActivityItem] = (0..<3).map { index in
        ActivityItem(
            id: "item-\(index)",
            entry: ActivityEntry(time: now.addingTimeInterval(-60 * Double(index)), level: .info, source: .app, message: "entry \(index)"),
            position: 2 - index)
    }

    @Test(
        "LOG-04 the detail shows the one selected entry, how many, or none once they are gone",
        arguments: [
            ([], "none"),
            (["item-1"], "one item-1"),
            (["item-0", "item-2"], "2 selected"),
            (["item-0", "item-1", "item-2"], "3 selected"),
            // Clear or the rotation removed some of them: only those left count.
            (["item-1", "gone-1"], "one item-1"),
            (["gone-1", "gone-2"], "none"),
        ] as [([String], String)])
    func detailOfSelection(selection: [String], expected: String) {
        let detail = ActivitySelection.detail(of: Set(selection), in: Self.items)

        let shown: String
        switch detail {
        case .none: shown = "none"
        case .one(let item): shown = "one \(item.id)"
        case .several(let count): shown = "\(count) selected"
        }
        #expect(shown == expected)
    }

    @Test(
        "LOG-04 entries that Clear or the rotation removed leave the selection, a restored one stays until the first read",
        arguments: [
            (["item-0", "gone-1"], true, ["item-0"]),
            (["gone-1"], true, []),
            (["item-0", "item-2"], true, ["item-0", "item-2"]),
            // Before the first read the log looks empty; the selection restored from UserDefaults must survive it.
            (["gone-1"], false, ["gone-1"]),
        ] as [([String], Bool, [String])])
    func prunesSelection(selection: [String], isLoaded: Bool, expected: [String]) {
        let items = isLoaded ? Self.items : []

        #expect(ActivitySelection.pruned(Set(selection), items: items, isLoaded: isLoaded) == Set(expected))
    }

    @Test(
        "LOG-04 Copy copies only the selected entries, oldest first, and nothing without a selection",
        arguments: [
            // Without a selection Copy is disabled: ⌘A, then ⌘C copies every shown entry (the user, 2026-10-29).
            ([], "", nil),
            (["Hid !11 #9", "GET /api/json in 0.19s"], "", ["GET /api/json in 0.19s", "Hid !11 #9"]),
            // A selected entry the search hides isn't copied.
            (["Hid !11 #9", "Check now"], "hid", ["Hid !11 #9"]),
        ] as [([String], String, [String]?)])
    func copiesTheSelection(selected: [String], search: String, expected: [String]?) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "activity-view-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = ActivityLog(folder: folder, now: { Self.now })
        let store = ActivityStore(
            log: log, requests: RequestCapture(folder: folder.appending(path: "requests")),
            checkTimes: CheckTimes(folder: folder, now: { Self.now }), now: { Self.now })
        for (minutesAgo, level, source, message) in [
            (3.0, ActivityEntry.Level.debug, ActivityEntry.Source.jenkins, "GET /api/json in 0.19s"),
            (2, .info, .app, "Check now"),
            (1, .info, .app, "Hid !11 #9"),
        ] {
            await log.append(ActivityEntry(
                time: Self.now.addingTimeInterval(-minutesAgo * 60), level: level, source: source, message: message))
        }
        await store.reload()
        store.searchText = search
        let ids = Set(store.items.filter { selected.contains($0.entry.message) }.map(\.id))

        let lines = ActivitySelection.copyText(of: ids, in: store)?.split(separator: "\n").map(String.init)

        #expect(lines?.count == expected?.count)
        for (line, message) in zip(lines ?? [], expected ?? []) {
            #expect(line.hasSuffix(message), "\(line)")
        }
    }

    @Test(
        "LOG-04 the subtitle counts the entries, and how many of them show while a filter or the search narrows the list",
        arguments: [
            (182, 182, ActivityLevelFilter.everything, nil, "", "182 entries"),
            (1, 1, .everything, nil, "", "1 entry"),
            (12, 182, .problems, nil, "", "12 of 182 entries"),
            (64, 182, .everything, .gitlab, "", "64 of 182 entries"),
            (3, 182, .everything, nil, "timeout", "3 of 182 entries"),
            (0, 182, .problems, .alerts, "", "0 of 182 entries"),
            // Spaces alone search nothing.
            (182, 182, .everything, nil, "  ", "182 entries"),
            // An empty log has no subtitle.
            (0, 0, .problems, nil, "", nil),
        ] as [(Int, Int, ActivityLevelFilter, ActivityEntry.Source?, String, String?)])
    func subtitle(matching: Int, total: Int, level: ActivityLevelFilter, source: ActivityEntry.Source?, search: String, expected: String?) {
        let isNarrowed = ActivityContentData.isNarrowed(level: level, source: source, search: search)

        #expect(ActivityContentData.subtitle(isLoaded: true, matching: matching, total: total, isNarrowed: isNarrowed) == expected)
        // Before the first read nothing is known yet.
        #expect(ActivityContentData.subtitle(isLoaded: false, matching: matching, total: total, isNarrowed: isNarrowed) == nil)
    }

    @Test("LOG-04 the pills: OK and 2xx green, problems red, Jenkins blue, GitLab orange, others neutral")
    func pills() {
        let outcomes: [(ActivityEntry.Outcome, ActivityPillTint)] = [
            (.ok("200"), .success), (.ok("OK"), .success), (.ok("RESOLVED"), .success),
            (.failed("500"), .problem), (.failed("TIMEOUT"), .problem), (.warning("SLOW"), .problem),
            // Running and neutral outcomes stay neutral, so blue means Jenkins only.
            (.running("RUNNING"), .neutral), (.neutral("ABORTED"), .neutral),
        ]
        for (outcome, expected) in outcomes {
            #expect(ActivityPillTint(outcome) == expected, "\(outcome)")
        }
        let sources: [(ActivityEntry.Source, ActivityPillTint)] = [
            (.jenkins, .jenkins), (.gitlab, .gitlab), (.alerts, .neutral), (.settings, .neutral), (.app, .neutral),
        ]
        for (source, expected) in sources {
            #expect(ActivityPillTint(source) == expected, "\(source)")
        }
        // Neutral pills take the hierarchical styles; the others their system color.
        #expect(ActivityPillTint.neutral.color == nil)
        #expect(ActivityPillTint.problem.color == .red)
    }

    @Test(
        "LOG-04 the view shows an alert's message without its emoji; the stored text keeps it",
        arguments: [
            ("❌ !16 #3 FAILURE (alert)", "!16 #3 FAILURE (alert)"),
            ("✅ !14 #2 SUCCESS (alert)", "!14 #2 SUCCESS (alert)"),
            ("⚠️ !1 #7 UNSTABLE (alert)", "!1 #7 UNSTABLE (alert)"),
            ("⏹ !1 #7 ABORTED (alert)", "!1 #7 ABORTED (alert)"),
            // Only a leading emoji goes: not a number, a word or an emoji in the middle.
            ("2 builds failed", "2 builds failed"),
            ("!16 #3 ❌ finished", "!16 #3 ❌ finished"),
            ("❌", "❌"),
        ])
    func displayMessage(message: String, expected: String) {
        let entry = ActivityEntry(time: Self.now, level: .info, source: .alerts, message: message)
        let item = ActivityItem(id: "alert", entry: entry, position: 0)

        #expect(item.displayMessage == expected)
        #expect(item.entry.message == message)
    }

    @Test("LOG-04 the whole entry names the outcome by its label, not as the file stores it")
    func fullTextUsesTheLabel() {
        let entry = ActivityEntry(
            time: Self.now, level: .info, source: .jenkins, message: "!16 #3 finished", outcome: .failed("FAILURE"))
        let text = ActivityItem(id: "failure", entry: entry, position: 0).fullText(in: .gmt)

        #expect(text.contains("info · Jenkins · FAILURE"))
        #expect(!text.contains("failed:"))
    }
}
