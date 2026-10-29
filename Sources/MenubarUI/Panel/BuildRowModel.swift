import Foundation
import MenubarCore

/// What a build row shows and offers (PIPE-02, PIPE-03, WATCH-04, APP-06): the state's symbol, the title, the facts
/// line in three parts, the progress or the failures, and the links of its context menu.
public struct BuildRowModel: Hashable, Sendable, Identifiable {
    /// How far a running build is (PIPE-02).
    public enum Progress: Hashable, Sendable {
        /// elapsed over the estimate, from 0 to 1
        case fraction(Double)
        /// without an estimate, or past it: a bar standing at 100 % would read as stalled
        case indeterminate
    }

    public var build: Build
    public var state: BuildState
    /// Jenkins' `objectDisplayName`; the job name when it is empty or missing (PIPE-02)
    public var title: String
    /// "!12 #7" or "feature/foo #3", after "by Sam Lee · " for a watched build (WATCH-04)
    public var reference: String
    /// "by Sam Lee" for a watched build; `nil` for mine
    public var byline: String?
    /// the project's name while there are several, first on line 2 (plan Phase 13); `nil` with one
    public var project: String?
    /// "!12 #7" or "feature/foo #3"; only "#3" when the title already is the label, so line 2 doesn't repeat it
    /// (review PANEL-02)
    public var buildName: String
    /// "▶ build, tests" while running, the result like "FAILURE" once finished; `nil` while no stage runs
    public var status: String?
    /// "0h05m elapsed · ~0h20m left" while running, "0h12m · finished 30m ago" once finished
    public var timing: String
    /// the timing without a finished build's trailing "finished 30m ago", for a row short of room; the whole timing
    /// while running
    public var timingWithoutAge: String
    /// the progress bar of a running build; `nil` once finished
    public var progress: Progress?
    /// "failed: tests, deploy · Failed tests: 3 of 1200" when known; `nil` otherwise
    public var failures: String?
    /// the links of the context menu, in order: the MR or the branch in GitLab, the build, its console and its test
    /// results (PIPE-03); none without the job URL in Team
    public var links: [BuildLink]
    /// the rebuild of the job started from the app: "Rebuilding…" with Cancel while queued, or its failure (PIPE-09)
    public var rebuild: JenkinsRebuild?
    /// whether the menu and the detail offer Rebuild: for a finished build, with the job URL in Team (PIPE-09)
    public var offersRebuild: Bool
    /// Jenkins's Build with Parameters page of the job, which "Rebuild with Changes…" opens (PIPE-09)
    public var rebuildWithChanges: URL?

    /// the build's page, which a click on the row opens
    public var buildPage: BuildLink? {
        links.first { $0.kind == .build }
    }

    public var id: BuildID { build.id }

    /// Returns the model of a build's row.
    ///
    /// - Parameters:
    ///   - build: the build
    ///   - now: the current time, for the elapsed time, the ETA and the age
    ///   - jobURL: the team's Jenkins multibranch job; `nil` gives no links into Jenkins
    ///   - rebuild: the job's rebuild, from `PipelinesStore.rebuilds` (PIPE-09)
    public init(build: Build, now: Date, jobURL: URL?, rebuild: JenkinsRebuild? = nil, project: String? = nil) {
        self.build = build
        self.project = project
        self.rebuild = rebuild
        offersRebuild = jobURL != nil && !build.isRunning
        rebuildWithChanges = offersRebuild
            ? jobURL.map { PipelineRules.buildWithParametersURL(job: build.job, jobURL: $0) } : nil
        state = BuildState(build)
        title = Self.title(of: build)
        let number = "#" + String(build.number)
        buildName = title == build.label ? number : "\(build.label) \(number)"
        if build.kind == .watched, let author = build.author, !author.isEmpty {
            byline = "by \(author)"
        } else {
            byline = nil
        }
        reference = ([project, byline].compactMap { $0 } + [buildName]).joined(separator: " · ")

        switch build.phase {
        case .running:
            let running = build.runningStages
            status = running.isEmpty ? nil : "▶ " + running.joined(separator: ", ")
            timing = ([Formatting.elapsed(build, now: now)] + [Formatting.remaining(build, now: now)].compactMap { $0 })
                .joined(separator: " · ")
            timingWithoutAge = timing
            if let fraction = build.progress(at: now), fraction < 1 {
                progress = .fraction(fraction)
            } else {
                progress = .indeterminate
            }
        case .finished(let result, let duration):
            status = result.rawValue
            let finished = build.finishedAt ?? now
            timing = "\(Formatting.duration(duration)) · finished \(Formatting.age(since: finished, now: now)) ago"
            timingWithoutAge = Formatting.duration(duration)
            progress = nil
        }
        var failures: [String] = []
        if build.result != nil, let failed = build.failedStages, !failed.isEmpty {
            failures.append("failed: " + failed.joined(separator: ", "))
        }
        if build.result != nil, let tests = Formatting.failedTests(build.testCounts) {
            failures.append(tests)
        }
        self.failures = failures.isEmpty ? nil : failures.joined(separator: " · ")

        links = jobURL.map { PipelineRules.links(of: build, jobURL: $0) } ?? []
    }

    /// the second line as one text: the reference, the status and the timing, joined with " · "
    public var facts: String {
        ([reference, status].compactMap { $0 } + [timing]).joined(separator: " · ")
    }

    /// the words search matches: the title, the label, the job and the author
    var searchText: [String] {
        [title, build.label, build.job, build.author ?? ""]
    }

    /// The title a row shows: Jenkins' title, or the job name, `MR-12` or a branch's decoded name (PIPE-02).
    static func title(of build: Build) -> String {
        if let title = build.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return build.mergeRequestIID == nil ? build.label : build.job
    }
}
