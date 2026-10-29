import Foundation
import MenubarCore

/// What the Pipelines section shows, as plain values: the panel's values and the watched jobs not checked yet. The
/// views take it from the stores; the gallery and the tests build it from fixtures.
public struct PipelinesData: Sendable {
    /// the stores' values, as the panel takes them
    public var panel: PanelData
    /// the watched jobs Jenkins wasn't asked about yet, oldest watched first (WATCH-06)
    public var waiting: [WatchedJob]

    public init(panel: PanelData, waiting: [WatchedJob] = []) {
        self.panel = panel
        self.waiting = waiting
    }

    /// Returns what the stores hold now.
    ///
    /// - Parameters:
    ///   - model: the app's model
    ///   - now: the time the rows count from
    @MainActor
    public init(_ model: AppModel, now: Date) {
        panel = PanelView.data(model, now: now)
        waiting = model.pipelines.watchedJobs.filter(\.isWaiting).map(\.watched)
    }

    /// the team's Jenkins multibranch job; `nil` without one
    var jobURL: URL? { panel.team.jenkinsJob }

    /// every job the list shows without a search: mine, the watched ones and the waiting ones
    public var jobs: Set<String> {
        guard panel.jenkins.problem != .teamValuesMissing else {
            return []
        }
        return Set(panel.jenkins.mine.map(\.jobKey) + panel.jenkins.watched.map(\.jobKey) + waiting.map(\.job))
    }

    /// Returns what the list shows of a job, unfiltered by the search: its build, or its waiting entry.
    ///
    /// - Parameter job: the job
    /// - Returns: the item; `nil` when the job isn't in the list
    func item(_ job: String) -> PipelinesItem? {
        guard jobs.contains(job) else {
            return nil
        }
        if let build = (panel.jenkins.mine + panel.jenkins.watched).first(where: { $0.jobKey == job }) {
            return .build(panel.jenkins.row(build, now: panel.now, jobURL: jobURL))
        }
        return waiting.first { $0.job == job }.map(PipelinesItem.waiting)
    }
}

/// A selectable row of the Pipelines list: a build, or a watched job Jenkins wasn't asked about yet (WATCH-06).
enum PipelinesItem: Hashable, Sendable, Identifiable {
    case build(BuildRowModel)
    case waiting(WatchedJob)

    /// the job's key, the row's stable id across checks: the job, or `<project>/<job>` for another project's
    var id: String {
        switch self {
        case .build(let row): row.build.jobKey
        case .waiting(let watched): watched.job
        }
    }
}

/// What the Pipelines list shows of a ``PipelinesData`` after the search (`docs/design/pipelines.md`, List): the
/// problem rows, My Builds, Watching, the link rows, or the empty state. Pure, so the tests and the gallery get the same
/// answers as the window.
struct PipelinesListModel: Sendable {
    /// What My Builds holds.
    enum MyBuilds: Hashable, Sendable {
        case rows([BuildRowModel])
        /// two placeholder rows: no check has answered yet (OD-01)
        case placeholder
        /// PIPE-06's text, above the watched builds
        case note(String)
    }

    /// The empty state: PIPE-06's text as the title, with its next steps.
    struct Empty: Hashable, Sendable {
        var title: String
        /// "Watch a Build…", when no job of mine was found
        var offersWatch: Bool
        /// "Show 3 Hidden Builds", when every build is hidden by hand
        var showHiddenTitle: String?
        /// "All Builds in Jenkins"
        var allBuilds: URL?
    }

    var problems: [PanelModel.ProblemItem]
    /// My Builds; `nil` when it doesn't show
    var myBuilds: MyBuilds?
    /// the watched builds that show, then the waiting jobs
    var watching: [PipelinesItem]
    /// "All Builds in Jenkins"; `nil` when it doesn't show
    var allBuilds: URL?
    /// "Show 2 Hidden Builds"; `nil` when it doesn't show
    var showHiddenTitle: String?
    /// the empty state instead of the sections; `nil` when the list has something to show
    var empty: Empty?
    /// the search text, trimmed; empty without a search
    var query: String
    /// the team's Jenkins multibranch job, for the waiting jobs' pages
    var jobURL: URL?

    /// Returns the page a row opens: the build's, or a waiting job's job page.
    func page(of item: PipelinesItem) -> URL? {
        switch item {
        case .build(let row): row.buildPage?.url
        case .waiting(let watched): jobURL.map { PipelineRules.jobURL(job: watched.job, jobURL: $0) }
        }
    }

    /// whether a search finds no build at all, which shows the system's no-results view
    var findsNothing: Bool {
        guard !query.isEmpty else {
            return false
        }
        if case .rows(let rows)? = myBuilds, !rows.isEmpty {
            return false
        }
        return watching.isEmpty
    }

    /// Returns what the list shows.
    ///
    /// - Parameters:
    ///   - data: the stores' values
    ///   - query: the search text; empty shows everything
    init(_ data: PipelinesData, query: String = "") {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query
        jobURL = data.jobURL
        let jenkins = data.panel.jenkins
        problems = MainWindowProblems.appWide(jenkins: jenkins.problem, update: data.panel.update)
        guard !MainWindowProblems.teamValuesMissing(jenkins.problem) else {
            // TEAM-03: the team row alone; without the job URL there is no link row either.
            myBuilds = nil
            watching = []
            allBuilds = nil
            showHiddenTitle = nil
            empty = nil
            return
        }
        if let problem = jenkins.problemItem, jenkins.problem != .offline {
            problems.append(problem)
        }

        let searching = !query.isEmpty
        let now = data.panel.now
        let jobURL = data.jobURL
        let row = { (build: Build) in
            jenkins.row(build, now: now, jobURL: jobURL)
        }
        let mine = jenkins.mine.map(row)
        let watchedRows = jenkins.watched.map { PipelinesItem.build(row($0)) }
        let allWatching = watchedRows + data.waiting.map(PipelinesItem.waiting)
        watching = allWatching.filter { Self.matches(query, $0) }
        let shownMine = mine.filter { Self.matches(query, .build($0)) }
        let hiddenTitle = PipelinesStore.showHiddenTitle(count: jenkins.hiddenCount)

        var empty: Empty?
        if !jenkins.hasLoaded && jenkins.problem == nil {
            myBuilds = searching ? nil : .placeholder
        } else if !shownMine.isEmpty {
            myBuilds = .rows(shownMine)
        } else if !searching, let state = jenkins.emptyState {
            if allWatching.isEmpty {
                myBuilds = nil
                empty = Self.empty(state, hiddenTitle: hiddenTitle, allBuilds: jobURL)
            } else {
                // PIPE-06: the text shows above the watched builds, as a note.
                myBuilds = .note(state.message)
            }
        } else {
            // A problem without a cached job list shows the row alone (JERR-05), and a search hides the section.
            myBuilds = nil
        }
        self.empty = empty
        // The empty state carries the link rows as its actions, and a search hides them, as the panel does.
        let showsLinks = !searching && empty == nil
        allBuilds = showsLinks ? jobURL : nil
        showHiddenTitle = showsLinks ? hiddenTitle : nil
    }

    /// Returns PIPE-06's empty state with its next steps.
    private static func empty(_ state: PipelinesEmptyState, hiddenTitle: String?, allBuilds: URL?) -> Empty {
        switch state {
        case .noJobs:
            Empty(title: state.message, offersWatch: true, showHiddenTitle: nil, allBuilds: allBuilds)
        case .noBuilds:
            // Every build hidden by hand: showing them again is the next step; hidden by the settings: Jenkins.
            Empty(title: state.message, offersWatch: false, showHiddenTitle: hiddenTitle,
                  allBuilds: hiddenTitle == nil ? allBuilds : nil)
        }
    }

    /// Returns whether a row matches the search, ignoring case: the title, the label with the build number and the
    /// author (WIN-03). Stage names don't match: "tests" would match nearly every build (`pipelines.md`, Search).
    ///
    /// - Parameters:
    ///   - query: the trimmed search text
    ///   - item: the row
    /// - Returns: `true` without a search
    static func matches(_ query: String, _ item: PipelinesItem) -> Bool {
        let words: [String]
        switch item {
        case .build(let row): words = [row.title, row.build.id.label, row.build.author ?? ""]
        case .waiting(let watched): words = [watched.label]
        }
        return PanelModel.matches(query, words)
    }
}
