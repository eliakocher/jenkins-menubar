import Foundation

/// A finished build of a job's recent history, as Jenkins' build list tells it (PIPE-10).
public struct RecentBuild: Hashable, Sendable {
    public var number: Int
    public var result: BuildResult
    /// the commit the build started from, lowercase; `nil` when Jenkins named none. See
    /// ``JenkinsClient/recentBuilds(job:repository:limit:)`` for which commit that is.
    public var commit: String?

    public init(number: Int, result: BuildResult, commit: String?) {
        self.number = number
        self.result = result
        self.commit = commit.map { $0.lowercased() }
    }
}

/// A recent build with its stages, when they are known (PIPE-10).
public struct BuildRun: Hashable, Sendable {
    public var build: RecentBuild
    /// the stages; `nil` when not loaded, which is meant for a successful build: all its stages passed
    public var stages: [Stage]?

    public init(build: RecentBuild, stages: [Stage]?) {
        self.build = build
        self.stages = stages
    }

    /// How a stage went in this run.
    enum Outcome {
        case passed
        case failed
        /// not run, aborted, still running, or the stages are unknown
        case unknown
    }

    func outcome(ofStage name: String) -> Outcome {
        guard let stages else {
            return build.result == .success ? .passed : .unknown
        }
        switch stages.first(where: { $0.name == name })?.status {
        case Stage.Status.success?: return .passed
        case Stage.Status.failed?, Stage.Status.unstable?: return .failed
        default: return .unknown
        }
    }
}

/// What the build detail says of one failed stage of a build, from the job's recent history (PIPE-10).
public enum FlakyHint: Hashable, Sendable {
    /// the stage passed in another build of the same commit, so the failure is probably a flake
    case passedOnSameCommit(stage: String, build: Int)
    /// the stage failed in some of the recent runs, and passed in others
    case failedBefore(stage: String, failed: Int, of: Int)

    public var stage: String {
        switch self {
        case .passedOnSameCommit(let stage, _), .failedBefore(let stage, _, _): stage
        }
    }
}

/// The rule behind "likely flaky" (PIPE-10): judges the failed stages of a build by the job's recent builds.
public enum FlakyRule {
    /// how many finished builds the history looks at, the judged one included
    public static let window = 10

    /// Returns the hints for the failed stages of a build.
    ///
    /// A failed (or unstable) stage is likely flaky when it passed in another build of the same commit. Otherwise, when it
    /// failed in at least two of the last ``window`` builds, the hint says how many; a stage that failed in every one of
    /// them is a real failure, and one that failed only in this build is a new one, so neither gets a hint. Aborted and
    /// not-built builds say nothing, so they aren't counted. The hints with a flaky verdict come first; each group
    /// keeps the order of the stages.
    ///
    /// - Parameters:
    ///   - build: the judged build; it must be among the history's builds
    ///   - stages: the stages of the judged build
    ///   - history: the job's recent finished builds, with stages for those the rule needs: the failed and unstable ones,
    ///     and those of the same commit
    /// - Returns: the hints; empty when the history says nothing useful
    public static func hints(for build: RecentBuild, stages: [Stage], history: [BuildRun]) -> [FlakyHint] {
        let runs = history
            .filter { [.success, .unstable, .failure].contains($0.build.result) }
            .sorted { $0.build.number > $1.build.number }
            .prefix(window)
        guard runs.contains(where: { $0.build.number == build.number }) else { return [] }
        var failedNames: [String] = []
        for stage in stages where stage.status == .failed || stage.status == .unstable {
            if !failedNames.contains(stage.name) {
                failedNames.append(stage.name)
            }
        }
        var flaky: [FlakyHint] = []
        var counted: [FlakyHint] = []
        for name in failedNames {
            if let commit = build.commit,
                let same = runs.first(where: {
                    $0.build.number != build.number && $0.build.commit == commit && $0.outcome(ofStage: name) == .passed
                })
            {
                flaky.append(.passedOnSameCommit(stage: name, build: same.build.number))
                continue
            }
            let failed = runs.filter { $0.build.number == build.number || $0.outcome(ofStage: name) == .failed }.count
            if failed >= 2 && failed < runs.count {
                counted.append(.failedBefore(stage: name, failed: failed, of: runs.count))
            }
        }
        return flaky + counted
    }

    /// Returns the builds whose stages the rule needs: the failed and unstable ones, and those of the judged build's
    /// commit, within the window.
    ///
    /// - Parameters:
    ///   - build: the judged build
    ///   - recent: the job's recent finished builds
    /// - Returns: the numbers of the builds, newest first, without the judged build
    public static func needingStages(for build: RecentBuild, in recent: [RecentBuild]) -> [Int] {
        recent
            .filter { [.success, .unstable, .failure].contains($0.result) }
            .sorted { $0.number > $1.number }
            .prefix(window)
            .filter { $0.number != build.number }
            .filter { $0.result != .success || ($0.commit != nil && $0.commit == build.commit) }
            .map(\.number)
    }
}
