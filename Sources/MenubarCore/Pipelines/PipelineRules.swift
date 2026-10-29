import Foundation

/// Whether a build shows, and if not, why (HIDE-01 to HIDE-04).
public enum BuildVisibility: String, Hashable, Sendable, CaseIterable {
    case shown
    /// hidden by hand until the job's next build; counts in "Show N Hidden Builds" (HIDE-01)
    case hiddenByHand
    /// hidden by the settings, or because its MR is merged; counted nowhere (HIDE-02, HIDE-03, HIDE-04)
    case hiddenAutomatically
}

/// The build counts of the status icon (PIPE-05).
public struct BuildCounts: Hashable, Sendable {
    public var running: Int
    /// finished with FAILURE
    public var failed: Int
    public var unstable: Int
    /// finished with SUCCESS
    public var successful: Int

    public init(running: Int = 0, failed: Int = 0, unstable: Int = 0, successful: Int = 0) {
        self.running = running
        self.failed = failed
        self.unstable = unstable
        self.successful = successful
    }

    /// whether nothing is counted, so the status icon shows the idle image
    public var isEmpty: Bool {
        running == 0 && failed == 0 && unstable == 0 && successful == 0
    }

    /// the counts above 0, in the order the status icon shows them: running, failed, unstable, successful
    public var shown: [(kind: Kind, count: Int)] {
        [(Kind.running, running), (.failed, failed), (.unstable, unstable), (.successful, successful)].filter { $0.1 > 0 }
    }

    /// What a count counts.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case running
        case failed
        case unstable
        case successful
    }
}

/// What the Pipelines sections show when they have no build to show (PIPE-06).
public enum PipelinesEmptyState: Hashable, Sendable {
    /// the last lookup found no job of the user, who is named because the Jenkins and GitLab names may differ
    case noJobs(user: String)
    /// no build of mine shows and no watched build shows, as when every build is hidden
    case noBuilds

    /// the text of the empty row
    public var message: String {
        switch self {
        case .noJobs(let user): "No merge request builds by \(user) in Jenkins"
        case .noBuilds: "No builds to show"
        }
    }
}

/// A watched job with its last build, as the main window lists it (WATCH-06).
public struct WatchedJobStatus: Hashable, Sendable, Identifiable {
    public var watched: WatchedJob
    /// the job's last build; `nil` before a check found it
    public var build: Build?
    /// the build's page, or the job's before the first check; `nil` without a Jenkins job URL in Team
    public var url: URL?

    public init(watched: WatchedJob, build: Build?, url: URL?) {
        self.watched = watched
        self.build = build
        self.url = url
    }

    public var id: String { watched.job }

    /// "!2 #5", or just the label before the first check
    public var title: String {
        build.map { "\(watched.label) #\($0.number)" } ?? watched.label
    }

    /// RUNNING, the result like SUCCESS or NOT_BUILT, or WAITING before the first check
    public var state: String {
        guard let build else {
            return "WAITING"
        }
        return build.result?.rawValue ?? "RUNNING"
    }

    /// whether the job hasn't been checked yet
    public var isWaiting: Bool { build == nil }
}

/// A link of a build row's menu (PIPE-03).
public struct BuildLink: Hashable, Sendable, Identifiable {
    /// What a link opens.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// the MR of an `MR-<N>` job
        case mergeRequest
        /// the branch of another job, in GitLab
        case branch
        case build
        case console
        case testResults
    }

    public var kind: Kind
    /// the menu item, like "Open Merge Request !12"
    public var title: String
    public var url: URL

    public init(kind: Kind, title: String, url: URL) {
        self.kind = kind
        self.title = title
        self.url = url
    }

    public var id: Kind { kind }
}

/// The rules that turn the builds a check found into what the Pipelines sections and the status icon show. Pure, so the
/// views, the gallery and the tests get the same answers.
public enum PipelineRules {
    /// Returns whether a build shows (HIDE-01 to HIDE-04).
    ///
    /// The automatic rules win over hiding by hand, so a build hidden both ways isn't counted as hidden (HIDE-04):
    /// - the build of a merged MR, running ones too, while that setting is on (HIDE-03); branch jobs never;
    /// - a finished build once its setting's time has passed since it finished (HIDE-02); running builds never;
    /// - a build whose job and number were hidden by hand (HIDE-01).
    ///
    /// - Parameters:
    ///   - build: the build
    ///   - hidden: the build number hidden by hand, per job
    ///   - merged: the iids of the merged MRs among the MR jobs
    ///   - preferences: the hiding settings
    ///   - now: the current time
    /// - Returns: whether it shows, and why not
    public static func visibility(
        of build: Build,
        hidden: [String: Int],
        merged: Set<Int>,
        preferences: Preferences,
        now: Date
    ) -> BuildVisibility {
        if preferences.hidesMergedBuilds, let iid = build.mergeRequestIID, merged.contains(iid) {
            return .hiddenAutomatically
        }
        if let result = build.result, let finishedAt = build.finishedAt {
            let setting = result == .success ? preferences.hideSuccessfulAfter : preferences.hideFailedAfter
            if setting.hides(finishedFor: now.timeIntervalSince(finishedAt)) {
                return .hiddenAutomatically
            }
        }
        if hidden[build.job] == build.number {
            return .hiddenByHand
        }
        return .shown
    }

    /// Returns the counts of the builds shown (PIPE-05). ABORTED and other results aren't counted.
    ///
    /// - Parameter builds: the builds that show
    /// - Returns: the counts
    public static func counts(of builds: [Build]) -> BuildCounts {
        var counts = BuildCounts()
        for build in builds {
            switch build.result {
            case nil: counts.running += 1
            case .failure?: counts.failed += 1
            case .unstable?: counts.unstable += 1
            case .success?: counts.successful += 1
            default: break
            }
        }
        return counts
    }

    /// Returns what the sections show without builds (PIPE-06).
    ///
    /// - Parameters:
    ///   - state: the Jenkins state, with the last lookup of my jobs
    ///   - mine: my builds that show
    ///   - watched: the watched builds that show
    /// - Returns: the empty state; `nil` while builds show, and before the first lookup, when the view shows the
    ///   loading row or the problem
    public static func emptyState(state: JenkinsState, mine: [Build], watched: [Build]) -> PipelinesEmptyState? {
        guard let myJobs = state.myJobs else {
            return nil
        }
        if myJobs.isEmpty, let me = state.me, !me.isEmpty {
            return .noJobs(user: me)
        }
        return mine.isEmpty && watched.isEmpty ? .noBuilds : nil
    }

    /// Returns the links of a build, in the order of its menu (PIPE-03): its MR or its branch when Jenkins gave a GitLab
    /// link, then the build, its console output and its test results.
    ///
    /// - Parameters:
    ///   - build: the build
    ///   - jobURL: the team's multibranch job
    /// - Returns: the links
    public static func links(of build: Build, jobURL: URL) -> [BuildLink] {
        var links: [BuildLink] = []
        if let gitLab = build.gitLabURL {
            if build.mergeRequestIID != nil {
                links.append(BuildLink(kind: .mergeRequest, title: "Open Merge Request \(build.label)", url: gitLab))
            } else {
                links.append(BuildLink(kind: .branch, title: "Open Branch \(build.label) in GitLab", url: gitLab))
            }
        }
        let page = AlertContent.buildURL(job: build.job, number: build.number, jobURL: jobURL)
        links.append(BuildLink(kind: .build, title: "Open Build #\(build.number)", url: page))
        links.append(BuildLink(kind: .console, title: "Console Output", url: page.appending(path: "console")))
        links.append(BuildLink(kind: .testResults, title: "Test Results", url: page.appending(path: "testReport")))
        return links
    }

    /// Returns Jenkins's own Build with Parameters page of a job, which "Rebuild with Changes…" opens (PIPE-09). It
    /// shows the job's parameters to change before Jenkins builds.
    ///
    /// - Parameters:
    ///   - job: the job's name as in Jenkins URLs
    ///   - jobURL: the team's multibranch job
    /// - Returns: `<job URL>/job/<job>/build?delay=0sec`
    public static func buildWithParametersURL(job: String, jobURL: URL) -> URL {
        URL(string: Self.jobURL(job: job, jobURL: jobURL).absoluteString + "build?delay=0sec") ?? jobURL
    }

    /// Returns the URL of a job's page, `<job URL>/job/<job>/`.
    ///
    /// - Parameters:
    ///   - job: the job's name as in Jenkins URLs
    ///   - jobURL: the team's multibranch job
    /// - Returns: the URL
    public static func jobURL(job: String, jobURL: URL) -> URL {
        var root = jobURL.absoluteString
        while root.hasSuffix("/") {
            root.removeLast()
        }
        return URL(string: "\(root)/job/\(job)/") ?? jobURL
    }
}
