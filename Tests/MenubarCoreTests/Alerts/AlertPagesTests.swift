import Foundation
import Testing

@testable import MenubarCore

/// The alert window's pages (ALERT-03): one window, newest first.
@Suite("Alert pages")
struct AlertPagesTests {
    private static func alert(_ number: Int) -> BuildAlert {
        let build = Build(
            job: "MR-\(number)", number: number, title: "Title \(number)", kind: .mine,
            phase: .finished(result: .failure, duration: 600), startedAt: Date(timeIntervalSince1970: 1_792_800_000))
        let content = AlertContent.finished(
            build, failedStages: [], links: AlertContent.Links(build: URL(string: "https://jenkins.example.com/job/MR-\(number)/\(number)/")!))!
        return BuildAlert(kind: .finished, build: build, content: content)
    }

    private static func pages(_ count: Int) -> (pages: AlertPages, alerts: [BuildAlert]) {
        var pages = AlertPages()
        let alerts = (1...count).map(alert)
        for alert in alerts {
            pages.add(alert, notificationsOff: false)
        }
        return (pages, alerts)
    }

    @Test("ALERT-03 an alert that joins is the page shown, and the newest is 1 of N")
    func newestIsShown() {
        var (pages, alerts) = Self.pages(3)
        #expect(pages.current?.id == alerts[2].id)
        #expect(pages.position == "1 of 3")
        pages.next()
        pages.next()
        #expect(pages.current?.id == alerts[0].id)
        #expect(pages.position == "3 of 3")
        #expect(!pages.hasNext)
        // A new alert is shown at once, wherever the paging was.
        let fourth = Self.alert(4)
        pages.add(fourth, notificationsOff: true)
        #expect(pages.current?.id == fourth.id)
        #expect(pages.current?.notificationsOff == true)
        #expect(pages.position == "1 of 4")
        #expect(!pages.hasPrevious)
    }

    /// Which page is dismissed, from the three of a window whose second page (index 1) is shown.
    enum Dismissal: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case shown, newer, older

        var testDescription: String { rawValue }
    }

    @Test("ALERT-03 a dismissed page is followed by the next older one", arguments: Dismissal.allCases)
    func dismissing(_ dismissal: Dismissal) {
        var (pages, alerts) = Self.pages(3)  // newest first: alerts[2], alerts[1], alerts[0]
        pages.next()
        let shown = alerts[1]
        switch dismissal {
        case .shown:
            pages.dismiss(shown.id)
            #expect(pages.current?.id == alerts[0].id)
        case .newer:
            pages.dismiss(alerts[2].id)
            #expect(pages.current?.id == shown.id)
        case .older:
            pages.dismiss(alerts[0].id)
            #expect(pages.current?.id == shown.id)
        }
        #expect(pages.count == 2)
    }

    @Test("ALERT-03 the last page's successor is the one before it, and no page is left after the last")
    func dismissingTheLast() {
        var (pages, alerts) = Self.pages(2)
        pages.next()
        pages.dismiss(alerts[0].id)
        #expect(pages.current?.id == alerts[1].id)
        pages.dismiss(alerts[1].id)
        #expect(pages.isEmpty)
        #expect(pages.current == nil)
        // An id that isn't a page changes nothing.
        pages.dismiss(UUID())
        #expect(pages.isEmpty)
    }

    @Test("ALERT-03 Dismiss All empties the window, and the same alert twice is one page")
    func dismissAll() {
        var (pages, alerts) = Self.pages(5)
        pages.add(alerts[1], notificationsOff: false)
        #expect(pages.count == 5)
        #expect(pages.current?.id == alerts[1].id)
        pages.dismissAll()
        #expect(pages.isEmpty)
    }
}
