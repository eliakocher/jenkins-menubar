import Foundation

/// The last build of a followed Jenkins job: one of mine, or a watched one.
///
/// Taken from the job's `api/json` (`actions[objectDisplayName,objectUrl,contributorDisplayName]` and
/// `lastBuild[number,building,result,timestamp,estimatedDuration,duration]`), its `wfapi/describe` and its test
/// reports.
public struct Build: Codable, Hashable, Identifiable, Sendable {
    /// the job's name as in Jenkins URLs, still URL-encoded, like `MR-12` or `feature%252Ffoo`
    public var job: String
    /// the build number, 1 or more
    public var number: Int
    /// Jenkins' `objectDisplayName`, the MR or branch title; `nil` when Jenkins has none
    public var title: String?
    /// Jenkins' `objectUrl`: the merge request, or the branch in GitLab
    public var gitLabURL: URL?
    /// Jenkins' `contributorDisplayName`, shown for watched builds (WATCH-04)
    public var author: String?
    public var kind: JobKind
    public var phase: BuildPhase
    /// Jenkins' `timestamp`
    public var startedAt: Date
    /// Jenkins' `estimatedDuration`; `nil` when Jenkins has no estimate (it sends -1)
    public var estimatedDuration: TimeInterval?
    /// the stages from `wfapi/describe`; `nil` when they weren't asked for, or the request failed (PIPE-04)
    public var stages: [Stage]?
    /// the test counts, summed over the build's test reports; `nil` when not known
    public var testCounts: TestCounts?
    /// the project whose job this is; not stored, since each project keeps its builds in its own caches folder, so its
    /// store stamps it (plan Phase 13)
    public var project: ProjectID = .main

    private enum CodingKeys: String, CodingKey {
        case job, number, title, gitLabURL, author, kind, phase, startedAt, estimatedDuration, stages, testCounts
    }

    public init(
        job: String,
        number: Int,
        title: String? = nil,
        gitLabURL: URL? = nil,
        author: String? = nil,
        kind: JobKind,
        phase: BuildPhase,
        startedAt: Date,
        estimatedDuration: TimeInterval? = nil,
        stages: [Stage]? = nil,
        testCounts: TestCounts? = nil
    ) {
        self.job = job
        self.number = number
        self.title = title
        self.gitLabURL = gitLabURL
        self.author = author
        self.kind = kind
        self.phase = phase
        self.startedAt = startedAt
        self.estimatedDuration = estimatedDuration
        self.stages = stages
        self.testCounts = testCounts
    }

    public var id: BuildID { BuildID(job: job, number: number, project: project) }

    /// the key of the build's job among every project's: the job's name for the primary project (``ProjectID/main``),
    /// as before there were several, and `<project>/<job>` for another (plan Phase 13)
    public var jobKey: String { id.jobKey }

    /// Returns the build as a project's.
    ///
    /// - Parameter project: the project whose job it is
    /// - Returns: the build with that project
    public func stamped(_ project: ProjectID) -> Build {
        var build = self
        build.project = project
        return build
    }

    /// the job's label: `!12` for `MR-12`, otherwise the job name decoded twice, like `feature/foo`
    public var label: String { Self.label(forJob: job) }

    /// the MR's iid for a job named `MR-<iid>`, otherwise `nil` (a branch job)
    public var mergeRequestIID: Int? { Self.mergeRequestIID(forJob: job) }

    public var isRunning: Bool { phase == .running }

    /// the result once finished, otherwise `nil`
    public var result: BuildResult? {
        if case .finished(let result, _) = phase { result } else { nil }
    }

    /// when the build finished (its start plus its duration), otherwise `nil`
    public var finishedAt: Date? {
        if case .finished(_, let duration) = phase { startedAt.addingTimeInterval(duration) } else { nil }
    }

    /// the names of the stages Jenkins runs right now, in order; empty when not known
    public var runningStages: [String] {
        (stages ?? []).filter { $0.status == .inProgress }.map(\.name)
    }

    /// the names of the stages that failed, in order; `nil` when the stages aren't known
    public var failedStages: [String]? {
        stages.map { $0.filter { $0.status == .failed }.map(\.name) }
    }

    /// Returns how long a running build has been running.
    ///
    /// - Parameter now: the current time
    /// - Returns: the time since the start, never below 0
    public func elapsed(at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }

    /// Returns the time a running build still needs by Jenkins' estimate (PIPE-02).
    ///
    /// - Parameter now: the current time
    /// - Returns: the time left, never below 0; `nil` without an estimate
    public func remaining(at now: Date) -> TimeInterval? {
        estimatedDuration.map { max(0, $0 - elapsed(at: now)) }
    }

    /// Returns how far a running build is by Jenkins' estimate (PIPE-02).
    ///
    /// - Parameter now: the current time
    /// - Returns: the elapsed time over the estimate, from 0 to 1; `nil` without an estimate, for an indeterminate
    ///   progress bar
    public func progress(at now: Date) -> Double? {
        estimatedDuration.map { min(1, elapsed(at: now) / $0) }
    }

    /// Returns the label of a job: `!12` for `MR-12`, otherwise the name URL-decoded twice (WATCH-01).
    ///
    /// Jenkins encodes a branch name twice in its job URLs: `feature/foo` is `feature%252Ffoo`.
    ///
    /// - Parameter job: the job's name as in Jenkins URLs
    /// - Returns: the label
    public static func label(forJob job: String) -> String {
        if let iid = mergeRequestIID(forJob: job) {
            return "!\(iid)"
        }
        let once = job.removingPercentEncoding ?? job
        return once.removingPercentEncoding ?? once
    }

    /// Returns the MR's iid for a job named `MR-<iid>`.
    ///
    /// - Parameter job: the job's name as in Jenkins URLs
    /// - Returns: the iid, or `nil` for any other job
    public static func mergeRequestIID(forJob job: String) -> Int? {
        guard job.hasPrefix("MR-") else { return nil }
        let digits = job.dropFirst(3)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}

/// A job and one of its build numbers, which is how hidden builds and alerts refer to a build.
public struct BuildID: Codable, Hashable, Sendable, CustomStringConvertible {
    /// the job's name as in Jenkins URLs
    public var job: String
    public var number: Int
    /// the project whose job it is; ``ProjectID/main`` when it was stored before there were several projects
    public var project: ProjectID

    public init(job: String, number: Int, project: ProjectID = .main) {
        self.job = job
        self.number = number
        self.project = project
    }

    private enum CodingKeys: String, CodingKey {
        case job, number, project
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        job = try container.decode(String.self, forKey: .job)
        number = try container.decode(Int.self, forKey: .number)
        project = try container.decodeIfPresent(ProjectID.self, forKey: .project) ?? .main
    }

    /// the key of the job among every project's: the job's name for ``ProjectID/main``, `<project>/<job>` for another
    public var jobKey: String { BuildID.jobKey(job, project: project) }

    /// Returns the key of a project's job, as ``jobKey``.
    ///
    /// - Parameters:
    ///   - job: the job's name as in Jenkins URLs, which never holds a `/`
    ///   - project: the project
    /// - Returns: the key
    public static func jobKey(_ job: String, project: ProjectID) -> String {
        project == .main ? job : "\(project.rawValue)/\(job)"
    }

    /// Splits a job key into its project and job, as ``jobKey`` made it.
    ///
    /// - Parameter key: the key
    /// - Returns: the project and the job
    public static func split(jobKey key: String) -> (project: ProjectID, job: String) {
        if let slash = key.firstIndex(of: "/"), let project = ProjectID(rawValue: String(key[..<slash])) {
            return (project, String(key[key.index(after: slash)...]))
        }
        return (.main, key)
    }

    /// like `MR-1 #7`: the job name as in Jenkins URLs, for keys and debugging
    public var description: String { "\(job) #\(number)" }

    /// like `!1 #7`, or `feature/foo #3` for a branch job: the build as the UI and the Activity log name it (LOG-01)
    public var label: String { "\(Build.label(forJob: job)) #\(number)" }
}

/// Whether a build is shown because it is mine (PIPE-01) or because it is watched (WATCH-04).
public enum JobKind: String, Codable, Hashable, Sendable, CaseIterable {
    case mine
    case watched
}

/// Whether a build is running or has finished.
public enum BuildPhase: Codable, Hashable, Sendable {
    case running
    /// finished with Jenkins' `result`, after `duration`
    case finished(result: BuildResult, duration: TimeInterval)
}

/// The result of a finished Jenkins build, as Jenkins names it. Results other than the named ones, like
/// `NOT_BUILT`, are kept as they come.
public struct BuildResult: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    /// Jenkins' result string, like `SUCCESS`
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let success = BuildResult(rawValue: "SUCCESS")
    public static let unstable = BuildResult(rawValue: "UNSTABLE")
    public static let failure = BuildResult(rawValue: "FAILURE")
    public static let aborted = BuildResult(rawValue: "ABORTED")
    public static let notBuilt = BuildResult(rawValue: "NOT_BUILT")

    public var description: String { rawValue }
}

/// A stage of a pipeline build, from `wfapi/describe`.
public struct Stage: Codable, Hashable, Sendable {
    public var name: String
    public var status: Status
    /// Jenkins' `durationMillis`, in seconds
    public var duration: TimeInterval

    public init(name: String, status: Status, duration: TimeInterval) {
        self.name = name
        self.status = status
        self.duration = duration
    }

    /// The status of a stage, as `wfapi/describe` names it. Others are kept as they come.
    public struct Status: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        /// the status string, like `IN_PROGRESS`
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let success = Status(rawValue: "SUCCESS")
        public static let failed = Status(rawValue: "FAILED")
        public static let inProgress = Status(rawValue: "IN_PROGRESS")
        public static let unstable = Status(rawValue: "UNSTABLE")
        public static let aborted = Status(rawValue: "ABORTED")
        public static let notExecuted = Status(rawValue: "NOT_EXECUTED")
        public static let pausedPendingInput = Status(rawValue: "PAUSED_PENDING_INPUT")

        public var description: String { rawValue }
    }
}

/// The failed and total test counts of a build, summed over its test reports.
public struct TestCounts: Codable, Hashable, Sendable {
    public var failed: Int
    public var total: Int

    public init(failed: Int, total: Int) {
        self.failed = failed
        self.total = total
    }
}
