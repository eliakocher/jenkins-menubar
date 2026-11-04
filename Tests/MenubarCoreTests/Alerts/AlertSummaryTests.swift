import Foundation
import Testing

@testable import MenubarCore

/// The alert window with several items (ALERT-03, INBOX-14): one summary, not pages. Its title and butler follow what the
/// items are, and the newest item is the first row.
@Suite("Alert summary")
struct AlertSummaryTests {
    private static func build(_ number: Int, _ result: BuildResult) -> AlertWindowItem {
        let build = Build(
            job: "MR-\(number)", number: number, title: "Title \(number)", kind: .mine,
            phase: .finished(result: result, duration: 600), startedAt: Date(timeIntervalSince1970: 1_792_800_000))
        let content = AlertContent.finished(
            build, failedStages: [], links: AlertContent.Links(build: URL(string: "https://jenkins.example.com/job/MR-\(number)/\(number)/")!))!
        return AlertWindowItem(alert: BuildAlert(kind: .finished, build: build, content: content), notificationsOff: false)
    }

    private static func event(_ number: Int, _ kind: InboxEventKind) -> AlertWindowItem {
        AlertWindowItem(
            event: InboxEvent(
                id: "todo|\(number)", kind: kind, source: .local, title: "Item \(number)", reference: "group/project!\(number)",
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    /// what arrives, the oldest first, and what the summary says
    struct Case: Sendable, CustomTestStringConvertible {
        var items: [Item]
        var title: String
        var butler: AlertSummary.Butler
        var testDescription: String { title }
    }

    enum Item: Sendable { case ok, failed, unstable, goodNews, badNews }

    private static func items(_ list: [Item]) -> [AlertWindowItem] {
        list.enumerated().map { number, item in
            switch item {
            case .ok: build(number, .success)
            case .failed: build(number, .failure)
            case .unstable: build(number, .unstable)
            case .goodNews: event(number, .reviewRequested)
            case .badNews: event(number, .pipelineFailed)
            }
        }
    }

    @Test(
        "ALERT-03 the summary's title and butler: sad for all failures, happy for all good news, the caught butler for a mix",
        arguments: [
            Case(items: [.failed, .failed], title: "2 Builds Failed", butler: .sad),
            Case(items: [.failed, .unstable, .failed], title: "3 Builds Failed", butler: .sad),
            Case(items: [.ok, .ok, .ok], title: "3 Builds Succeeded", butler: .happy),
            Case(items: [.ok, .failed, .ok], title: "3 Builds Finished", butler: .mixed),
            Case(items: [.goodNews, .ok], title: "2 New", butler: .happy),
            Case(items: [.failed, .badNews], title: "2 New", butler: .sad),
            Case(items: [.failed, .goodNews, .ok], title: "3 New", butler: .mixed),
            Case(items: [.goodNews, .goodNews], title: "2 New", butler: .happy),
        ])
    func titleAndButler(_ test: Case) throws {
        let summary = try #require(AlertSummary.make(Self.items(test.items)))
        #expect(summary.title == test.title)
        #expect(summary.butler == test.butler)
        #expect(summary.rows.count == test.items.count)
    }

    @Test("INBOX-14 only the coffee break is mandatory: Esc leaves it be, every other item and every build can be dismissed")
    func coffeeBreakIsMandatory() {
        let coffee = AlertWindowItem(event: .coffeeBreak(line: "Warm cups.", at: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(coffee.isMandatory)
        #expect(!Self.event(1, .mentioned).isMandatory)
        #expect(!Self.build(2, .failure).isMandatory)
    }

    @Test("ALERT-03 one item or none is no summary; the newest item is the first row, and one that comes again moves to the top")
    func rowsAreNewestFirst() throws {
        var window = AlertWindowItems()
        #expect(AlertSummary.make(window.items) == nil)
        let first = Self.build(1, .failure), second = Self.event(2, .mentioned), third = Self.build(3, .success)
        window.add(first)
        #expect(window.single?.id == first.id)
        #expect(!window.isSummary)
        #expect(AlertSummary.make(window.items) == nil)
        window.add(second)
        window.add(third)
        #expect(window.single == nil)
        #expect(try #require(AlertSummary.make(window.items)).rows.map(\.id) == [third.id, second.id, first.id])
        window.add(first)
        #expect(window.items.map(\.id) == [first.id, third.id, second.id])
        #expect(window.count == 3)
        // A row that goes leaves the others; two left are still a summary, one left shows as itself.
        window.dismiss(third.id)
        #expect(window.items.map(\.id) == [first.id, second.id])
        window.dismiss("nothing")
        #expect(window.count == 2)
        window.dismiss(first.id)
        #expect(window.single?.id == second.id)
        window.dismiss(second.id)
        #expect(window.isEmpty)
    }

    @Test("ALERT-03 a row says the build's reference, title and duration, or the event's reference, target and kind")
    func rowWords() {
        let build = Self.build(7, .failure)
        #expect(build.summaryReference == "!7 #7")
        #expect(build.summaryTitle == "Title 7")
        #expect(build.summaryDetail?.isEmpty == false)
        let event = Self.event(210, .reviewRequested)
        #expect(event.summaryReference == "!210")
        #expect(event.summaryTitle == "Item 210")
        #expect(event.summaryDetail == "Review")
    }
}
