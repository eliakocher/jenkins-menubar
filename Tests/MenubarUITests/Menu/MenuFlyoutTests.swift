import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("MenuFlyout")
@MainActor
struct MenuFlyoutTests {
    private static let fixtures = Fixtures()

    @Test("APP-06 each flyout lists the window's sections, then Show in Window and the area's link")
    func sectionsAndCommands() {
        let f = Self.fixtures
        let watched = f.running(
            "MR-2", 14, "Retry the upload", startedMinutesAgo: 8, estimateMinutes: 20, kind: .watched, author: "Sam Lee")
        let data = f.panel(mine: f.typicalBuilds, watched: [watched], hiddenCount: 2)

        let pipelines = MenuFlyout(data, area: .pipelines)
        #expect(pipelines.sections.map(\.title) == ["My Builds", "Watching"])
        #expect(pipelines.sections.map(\.count) == ["2", "1"])
        // Watch a Build… is Pipelines' own action (the user, 2026-10-29).
        #expect(pipelines.commands.map(\.title) == [
            "Watch a Build…", "Show 2 Hidden Builds", "Show in Window", "All Builds in Jenkins",
        ])

        let mergeRequests = MenuFlyout(data, area: .mergeRequests)
        #expect(mergeRequests.sections.map(\.title) == ["My Merge Requests", "Review Requested", "Reviewed"])
        #expect(mergeRequests.commands.map(\.title) == ["Show in Window", "All Merge Requests in GitLab"])

        let workItems = MenuFlyout(data, area: .workItems)
        #expect(workItems.sections.map(\.title) == ["Committed", "Not Committed"])
        #expect(workItems.sections.map(\.count) == ["2", "3 of 45"])
        #expect(workItems.commands.map(\.title) == ["Show in Window", "All Work Items in GitLab"])

        // The keys move over the entries, then the commands.
        #expect(workItems.items.count == 5 + 2)
        #expect(workItems.items.last == .command(.link("All Work Items in GitLab", workItems.commandURL!)))
    }

    @Test("APP-06 a flyout lists at most 20 entries, then Show All N in Window")
    func capsTheEntries() {
        let f = Self.fixtures
        let mine = (1...16).map { f.finished("MR-\($0)", 1, "Build \($0)", .success, durationMinutes: 10, finishedMinutesAgo: Double($0)) }
        let watched = (17...25).map {
            f.finished("MR-\($0)", 1, "Build \($0)", .success, durationMinutes: 10, finishedMinutesAgo: Double($0), kind: .watched)
        }
        let flyout = MenuFlyout(f.panel(mine: mine, watched: watched), area: .pipelines)
        #expect(flyout.total == 25)
        #expect(flyout.entries.count == MenuFlyout.cap)
        // My Builds whole, then as many watched as fit.
        #expect(flyout.sections.map(\.entries.count) == [16, 4])
        // The header still counts the whole section.
        #expect(flyout.sections.map(\.count) == ["16", "9"])
        #expect(flyout.commands.contains(.showInWindow(all: 25)))
        #expect(flyout.commands.map(\.title).contains("Show All 25 in Window"))
    }

    @Test("APP-06 the entries say what tells them apart in their grey line")
    func entryLines() {
        let f = Self.fixtures
        let builds = MenuFlyout(f.panel(mine: f.typicalBuilds), area: .pipelines).entries
        #expect(builds.map(\.subtitle) == ["!12 #7 · build, tests · 5m of ~25m", "!16 #3 · failed: tests, deploy · 30m ago"])
        #expect(builds.map(\.symbol) == ["hourglass", "xmark.circle.fill"])
        // A click opens the build in Jenkins; a running build has its progress.
        #expect(builds[0].url?.absoluteString.contains("/job/MR-12/7") == true)
        #expect(builds[0].progress == .fraction(0.2))
        #expect(builds[1].progress == nil)

        let mergeRequests = MenuFlyout(f.panel(), area: .mergeRequests).entries
        #expect(mergeRequests.first?.subtitle == "!21 · Ready to merge · 5m ago")
        // In Review Requested, the badge's eye in orange; the line leaves "Review requested" to the header.
        let review = mergeRequests.first { $0.title == "Cache the label colors per project" }
        #expect(review?.symbol == "eye.circle.fill")
        #expect(review?.subtitle == "!24 · Missing 1 of 1 approval · by Sam Lee · 12m ago")
        #expect(review?.selection == .mergeRequest(URL(string: "https://gitlab.example.com/group/subgroup/project/-/merge_requests/24")!))

        let workItems = MenuFlyout(f.panel(), area: .workItems).entries
        // The slot is its value as a pill; the marker of an open related MR is the symbol.
        #expect(workItems.first?.pill?.shortTitle == "Q1")
        #expect(workItems.first?.subtitle == "#31 · 30m ago")
        #expect(workItems.first?.symbol == "arrow.triangle.pull")
        #expect(workItems.first { $0.title == "Fix the flaky upload test" }?.subtitle == "#38 · type::bug · 30m ago")
        // An open item without a related MR has no marker: every listed item is open.
        #expect(workItems.first { $0.title == "Fix the flaky upload test" }?.symbol == nil)
        // #31's open MR marker keeps the column; without any marker, the text starts at the rows' edge.
        #expect(MenuFlyout(f.panel(), area: .workItems).hasSymbolColumn)
        var unmarked = f.typicalWorkItems
        unmarked.markers = [:]
        #expect(!MenuFlyout(f.panel(workItems: unmarked), area: .workItems).hasSymbolColumn)
        #expect(MenuFlyout(f.panel(mine: f.typicalBuilds), area: .pipelines).hasSymbolColumn)
    }

    @Test("APP-06 a flyout without data says why, and placeholders before the first load")
    func notesAndPlaceholders() {
        let f = Self.fixtures
        let noToken = MenuFlyout(
            f.panel(mergeRequests: PanelData.MergeRequests(problem: .noToken(.gitLab))), area: .mergeRequests)
        #expect(noToken.note == PanelModel.SetupText.needsToken)
        #expect(noToken.entries.isEmpty)
        #expect(noToken.commands.first == .settings(.accounts))

        #expect(MenuFlyout(f.panel(hasLoaded: false), area: .pipelines).isPlaceholder)
        #expect(MenuFlyout(f.panel(mergeRequests: PanelData.MergeRequests(isLoading: true)), area: .mergeRequests).isPlaceholder)
        let empty = MenuFlyout(f.panel(mergeRequests: PanelData.MergeRequests(list: f.mergeRequests([]))), area: .mergeRequests)
        #expect(empty.note == "No open merge requests")
        #expect(MenuFlyout(f.panel(emptyState: .noJobs(user: "jdoe")), area: .pipelines).note
            == "No merge request builds by jdoe in Jenkins")
    }

    @Test("APP-06 a click on an entry shows it in the window, with Option it opens the page in the browser")
    func entryDestinations() {
        let f = Self.fixtures
        let data = f.panel(mine: f.typicalBuilds)
        let entries = [PanelAreaPick.pipelines, .mergeRequests, .workItems].compactMap {
            MenuFlyout(data, area: $0.area).entries.first
        }
        #expect(entries.count == 3)
        for entry in entries {
            #expect(entry.destination(option: false) == .window(entry.selection))
            #expect(entry.url != nil)
            #expect(entry.destination(option: true) == .browser(entry.url!))
        }
        #expect(entries.map(\.selection.section) == [.pipelines, .mergeRequests, .workItems])
        var withoutPage = entries[0]
        withoutPage.url = nil
        #expect(withoutPage.destination(option: true) == .window(withoutPage.selection))
    }

    @Test("PIPE-02 a running build's time against its estimate")
    func runningTime() {
        #expect(MenuEntry.short(5 * 60 + 59) == "5m")
        #expect(MenuEntry.short(65 * 60) == "1h05m")
        #expect(MenuEntry.short(-3) == "0m")
    }
}

private enum PanelAreaPick {
    case pipelines, mergeRequests, workItems

    var area: MainWindowSection {
        switch self {
        case .pipelines: .pipelines
        case .mergeRequests: .mergeRequests
        case .workItems: .workItems
        }
    }
}

extension MenuFlyout {
    /// the URL of the last command, a link
    fileprivate var commandURL: URL? {
        if case .link(_, let url)? = commands.last { url } else { nil }
    }
}
