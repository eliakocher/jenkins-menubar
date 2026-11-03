import Foundation
import Testing

@testable import MenubarCore

@Suite("Inbox seen")
@MainActor
struct InboxSeenTests {
    @Test("INBOX-07 an opened row stays seen across a restart, and the old and the surplus ids are dropped")
    func keepsAndPrunes() throws {
        let folder = try TemporaryFolder()
        let file = FileStore<[String: Date]>(url: folder.file("seen.json"), report: { _ in })
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let seen = InboxSeen(file: file, now: { start })
        #expect(!seen.isSeen("a"))
        seen.markSeen("a")
        #expect(seen.isSeen("a"))
        #expect(InboxSeen(file: file, now: { start }).isSeen("a"))
        seen.markUnseen("a")
        #expect(!InboxSeen(file: file, now: { start }).isSeen("a"))

        // 61 days later the id is gone.
        seen.markSeen("old")
        let later = InboxSeen(file: file, now: { start.addingTimeInterval(61 * 24 * 3600) })
        later.markSeen("new")
        #expect(!later.isSeen("old") && later.isSeen("new"))

        // At most `limit` ids stay, the newest.
        for index in 0..<(InboxSeen.limit + 5) {
            later.markSeen("id\(index)")
        }
        let reloaded = InboxSeen(file: file, now: { start.addingTimeInterval(61 * 24 * 3600) })
        let kept = (0..<(InboxSeen.limit + 5)).count { reloaded.isSeen("id\($0)") } + (reloaded.isSeen("new") ? 1 : 0)
        #expect(kept == InboxSeen.limit)
    }
}
