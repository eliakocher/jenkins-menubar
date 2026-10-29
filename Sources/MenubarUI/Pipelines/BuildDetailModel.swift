import Foundation
import MenubarCore
import SwiftUI

/// What `BuildDetailView` shows of a build or a waiting job (`docs/design/pipelines.md`, Detail): the header, the facts,
/// the stages or a note about them, and the links. Pure, so the gallery gets the same answers as the window.
struct BuildDetailModel: Hashable, Sendable {
    /// A read-only fact, like "Duration" and "0h12m".
    struct Fact: Hashable, Sendable, Identifiable {
        var label: String
        var value: String
        /// the result's state, which shows its symbol before the word
        var state: BuildState?
        var id: String { label }
    }

    /// A stage with its status and duration.
    struct StageRow: Hashable, Sendable, Identifiable {
        var index: Int
        var name: String
        var symbol: String
        /// the symbol's color; `nil` for the label color
        var color: Color?
        /// "successful", "failed", "not run" …
        var word: String
        /// "0h04m"; `nil` for a stage that didn't run
        var duration: String?
        var id: Int { index }
    }

    /// the build, or the waiting job
    var item: PipelinesItem
    /// the state's symbol: the build's, or `clock` for a waiting job
    var symbol: String
    var color: Color?
    /// the build's title, or the waiting job's label
    var title: String
    /// "!16 #3" or "by Sam Lee · !14 #3", or "WAITING"
    var reference: String
    /// "Open Build #3", or "Open Job in Jenkins" for a waiting job; `nil` without the job URL in Team
    var primary: BuildLink?
    /// whether "Hide Until the Next Build" shows: for builds only
    var canHide: Bool
    /// whether "Stop Watching" shows: for watched builds and waiting jobs
    var canStopWatching: Bool
    /// whether "Rebuild" shows: for finished builds (PIPE-09)
    var canRebuild: Bool
    /// whether "New Bug from This Build" shows: for finished failed or unstable builds (NEW-03)
    var canReportBug: Bool
    /// the job's rebuild: "Rebuilding…" with Cancel Rebuild while queued, or its failure (PIPE-09)
    var rebuild: JenkinsRebuild?
    /// Jenkins's Build with Parameters page, for "Rebuild with Changes…" in Links (PIPE-09)
    var rebuildWithChanges: URL?
    /// the running build's bar
    var progress: BuildRowModel.Progress?
    /// "0h05m elapsed · ~0h20m left", under the bar
    var timing: String?
    var facts: [Fact]
    /// whether the Stages section shows: not for a waiting job
    var showsStages: Bool
    var stages: [StageRow]
    /// a note in Stages instead of rows, or the waiting job's note
    var note: String?
    /// the finished build whose failed tests the Failed Tests section lists: one with test counts above 0 failed
    /// (PIPE-03); `nil` for any other build
    var failedTests: BuildID?
    /// the finished failed or unstable build with a failed stage, whose hint "likely flaky" shows next to Rebuild
    /// (PIPE-10); `nil` for any other build
    var flakyCheck: Build?
    /// the links except the build's own (PIPE-03)
    var links: [BuildLink]

    /// the Stages notes (`pipelines.md`, Stage notes)
    enum StageNote {
        static let notLoaded = "Stages are loaded only for running, failed and unstable builds"
        static let unknown = "Stages unknown: Jenkins is asked again at the next check"
        static let notStarted = "No stage has started yet"
        static let waiting = "Jenkins is asked at the next check"
    }

    /// Returns the detail of a selected job.
    ///
    /// - Parameters:
    ///   - job: the selected job
    ///   - data: the stores' values
    /// - Returns: `nil` when the job isn't in the list (hidden, dropped, no longer watched), which shows no selection
    init?(job: String, data: PipelinesData) {
        switch data.item(job) {
        case .build(let row)?:
            self.init(row: row, now: data.panel.now)
        case .waiting(let watched)?:
            self.init(waiting: watched, jobURL: data.jobURL)
        case nil:
            return nil
        }
    }

    private init(waiting watched: WatchedJob, jobURL: URL?) {
        item = .waiting(watched)
        symbol = "clock"
        color = .secondary
        title = watched.label
        reference = "WAITING"
        primary = jobURL.map {
            BuildLink(kind: .build, title: "Open Job in Jenkins", url: PipelineRules.jobURL(job: watched.job, jobURL: $0))
        }
        canHide = false
        canStopWatching = true
        canRebuild = false
        canReportBug = false
        rebuild = nil
        rebuildWithChanges = nil
        progress = nil
        timing = nil
        facts = []
        showsStages = false
        stages = []
        note = StageNote.waiting
        failedTests = nil
        flakyCheck = nil
        links = []
    }

    private init(row: BuildRowModel, now: Date) {
        let build = row.build
        item = .build(row)
        symbol = row.state.symbol
        color = row.state.color
        title = row.title
        reference = ([row.byline].compactMap { $0 } + [build.id.label]).joined(separator: " · ")
        primary = row.buildPage.map { BuildLink(kind: .build, title: "Open Build #\(String(build.number))", url: $0.url) }
        canHide = true
        canStopWatching = build.kind == .watched
        canRebuild = row.offersRebuild
        canReportBug = build.result == .failure || build.result == .unstable
        rebuild = row.rebuild
        rebuildWithChanges = row.rebuildWithChanges
        showsStages = true
        links = row.links.filter { $0.kind != .build }
        failedTests = nil
        flakyCheck = nil

        let started = Fact(label: "Started", value: Self.time(build.startedAt, now: now))
        switch build.phase {
        case .running:
            progress = row.progress
            timing = row.timing
            facts = [started]
            stages = Self.stageRows(build.stages ?? [])
            note = build.stages == nil ? StageNote.unknown : (build.stages?.isEmpty == true ? StageNote.notStarted : nil)
        case .finished(let result, let duration):
            progress = nil
            timing = nil
            var facts = [
                Fact(label: "Result", value: result.rawValue, state: row.state),
                Fact(label: "Duration", value: Formatting.duration(duration)),
                Fact(label: "Finished", value: "\(Formatting.age(since: build.finishedAt ?? now, now: now)) ago"),
                started,
            ]
            if let failed = build.failedStages, !failed.isEmpty {
                facts.append(Fact(label: "Failed stages", value: failed.joined(separator: ", ")))
            }
            if let tests = build.testCounts {
                if tests.failed > 0 {
                    failedTests = build.id
                }
                facts.append(Fact(label: "Failed tests", value: "\(String(tests.failed)) of \(String(tests.total))"))
            }
            self.facts = facts
            // PIPE-04: only running, failed and unstable builds have their stages asked for.
            if result != .failure && result != .unstable {
                stages = []
                note = StageNote.notLoaded
            } else if let known = build.stages {
                stages = Self.stageRows(known)
                note = nil
                if known.contains(where: { $0.status == .failed || $0.status == .unstable }) {
                    flakyCheck = build
                }
            } else {
                stages = []
                note = StageNote.unknown
            }
        }
    }

    /// Returns the stage rows, in Jenkins' order.
    private static func stageRows(_ stages: [Stage]) -> [StageRow] {
        stages.enumerated().map { index, stage in
            let look = look(of: stage.status)
            let ran = stage.status != .notExecuted
            return StageRow(
                index: index, name: stage.name, symbol: look.symbol, color: look.color, word: look.word,
                duration: ran ? Formatting.duration(stage.duration) : nil)
        }
    }

    /// Returns a stage status's symbol, color and word, in the vocabulary of `status-icon.md`.
    static func look(of status: Stage.Status) -> (symbol: String, color: Color?, word: String) {
        switch status {
        case .success: (BuildState.successful.symbol, BuildState.successful.color, "successful")
        case .failed: (BuildState.failed.symbol, BuildState.failed.color, "failed")
        case .unstable: (BuildState.unstable.symbol, BuildState.unstable.color, "unstable")
        case .inProgress: (BuildState.running.symbol, nil, "running")
        case .aborted: (BuildState.aborted.symbol, BuildState.aborted.color, "aborted")
        case .notExecuted: ("minus.circle", .secondary, "not run")
        case .pausedPendingInput: ("pause.circle", .secondary, "waiting for input")
        default: ("questionmark.circle", .secondary, status.rawValue.lowercased())
        }
    }

    /// Returns a start time in the user's short format, with the short date when it isn't today: "10:12".
    private static func time(_ date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .numeric, time: .shortened)
    }
}
