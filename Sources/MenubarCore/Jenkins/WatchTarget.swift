import Foundation

/// What Watch a Build… makes of the text it gets: the job to watch, or the reason it refuses (WATCH-01 to WATCH-03).
///
/// Watching takes two steps, as in the old plugin's `watch_target()` and `watch()`: ``parse(_:project:)`` reads the
/// text without asking anybody, then ``confirm(_:client:myJobs:)`` asks Jenkins whether it has the job.
public enum WatchTarget {
    /// Reads the job to watch from a link or a number, with the spaces around it trimmed (WATCH-01, WATCH-02).
    ///
    /// - `!12`, `MR-12`, `mr-12` and `12` give `MR-12`.
    /// - A merge request link of the team's GitLab project, with any suffix like `/diffs`, gives `MR-12`. The project
    ///   path is compared case-insensitively.
    /// - A build, job or console link under the team's Jenkins job URL gives the first job after it, still
    ///   URL-encoded, like `feature%252Ffoo`. A space typed by hand matches a `%20` of the job URL.
    ///
    /// - Parameters:
    ///   - text: what was pasted or typed
    ///   - project: the project whose GitLab project and Jenkins job the links must point into
    /// - Returns: the job's name as in Jenkins URLs, or why the text can't be watched
    public static func parse(_ text: String, project: Project) -> Result<String, WatchRefusal> {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let team = project.team
        if let iid = mergeRequestIID(text, prefixes: ["!", "MR-", "mr-"]) {
            return .success("MR-\(iid)")
        }
        let gitLab = withoutTrailingSlash(team.gitLabURL)
        if !gitLab.isEmpty, text.hasPrefix(gitLab + "/"), let separator = text.range(of: "/-/", range: text.index(text.startIndex, offsetBy: gitLab.count + 1)..<text.endIndex) {
            let path = text[text.index(text.startIndex, offsetBy: gitLab.count + 1)..<separator.lowerBound]
            guard path.lowercased() == team.gitLabProject.lowercased() else {
                return .failure(.otherProject(team.gitLabProject))
            }
            let rest = text[separator.upperBound...]
            guard rest.hasPrefix("merge_requests/"),
                let iid = Int(rest.dropFirst("merge_requests/".count).prefix { $0.isASCII && $0.isNumber })
            else {
                return .failure(.notAMergeRequest)
            }
            return .success("MR-\(iid)")
        }
        // A link typed by hand may have a space where the browser has %20.
        let link = text.replacingOccurrences(of: "%20", with: " ")
        let root = withoutTrailingSlash(team.jenkinsJobURL).replacingOccurrences(of: "%20", with: " ")
        if !root.isEmpty, link.hasPrefix(root + "/job/") {
            let job = link.dropFirst(root.count + "/job/".count).prefix { !"/?#".contains($0) }
            if !job.isEmpty {
                return .success(job.replacingOccurrences(of: " ", with: "%20"))
            }
        }
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            return .failure(.otherJenkins(jobURL: team.jenkinsJobURL))
        }
        return .failure(.notUnderstood)
    }

    /// Returns the project a text is watched in: the one whose Jenkins job or GitLab project a link points into, else
    /// the chosen one, as for a number like `!12` (plan Phase 13).
    ///
    /// - Parameters:
    ///   - text: what was pasted or typed
    ///   - projects: the projects, the primary one first
    ///   - chosen: the project the sheet has chosen
    /// - Returns: the project's id
    public static func project(of text: String, among projects: [Project], chosen: ProjectID) -> ProjectID {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            return chosen
        }
        return projects.first { project in
            if case .success = parse(trimmed, project: project) { true } else { false }
        }?.id ?? chosen
    }

    /// Asks Jenkins whether it has the job, and returns what the watched list shows for it (WATCH-01 to WATCH-03).
    ///
    /// A job of mine is refused before Jenkins is asked: it shows with my builds anyway.
    ///
    /// - Parameters:
    ///   - job: the job, from ``parse(_:project:)``
    ///   - client: the client, or why there is none (`JenkinsClient.make`)
    ///   - myJobs: my jobs, from the last lookup (PIPE-01)
    /// - Returns: the job with its label and title, or why it can't be watched
    /// - Throws: `CancellationError` when the task was cancelled while Jenkins was asked
    public static func confirm(
        _ job: String,
        client: Result<JenkinsClient, JenkinsError>,
        myJobs: Set<String>
    ) async throws(CancellationError) -> Result<WatchCandidate, WatchRefusal> {
        guard !myJobs.contains(job) else {
            return .failure(.mine(job: job))
        }
        let jenkins: JenkinsClient
        switch client {
        case .success(let made): jenkins = made
        case .failure(let error): return .failure(.problem(error.problem))
        }
        do {
            let status = try await jenkins.job(job)
            return .success(WatchCandidate(job: job, label: Build.label(forJob: job), title: status.title))
        } catch let error as JenkinsError {
            return .failure(error.problem == .gone ? .noJob(job: job) : .problem(error.problem))
        } catch {
            throw CancellationError()
        }
    }

    /// Returns the copied text the Watch a Build… sheet starts with, when it looks like something to watch (WATCH-01).
    ///
    /// That is a number like `!12`, `MR-12` or `12`, or a link with `/job/` or `/-/merge_requests/`, unless it is a
    /// link to a job already watched.
    ///
    /// - Parameters:
    ///   - text: the clipboard's text
    ///   - watchedJobs: the jobs watched now
    /// - Returns: the text without the spaces around it, or `nil` to leave the sheet empty
    public static func suggestion(fromClipboard text: String, watchedJobs: [String]) -> String? {
        let copied = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard watchedJobs.allSatisfy({ !copied.contains("/job/\($0)/") }),
            copied.range(of: #"^(!|MR-)?[0-9]+$|^https?://\S+/(job/|-/merge_requests/)"#, options: .regularExpression) != nil
        else {
            return nil
        }
        return copied
    }

    private static func mergeRequestIID(_ text: String, prefixes: [String]) -> Int? {
        let digits = prefixes.first { text.hasPrefix($0) }.map { text.dropFirst($0.count) } ?? text[...]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    private static func withoutTrailingSlash(_ text: String) -> String {
        var text = text
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }
}

/// A job Jenkins confirmed, ready to be watched.
public struct WatchCandidate: Hashable, Sendable {
    /// the job's name as in Jenkins URLs
    public var job: String
    /// the label it shows with, like `!12` or `feature/foo`
    public var label: String
    /// Jenkins' `objectDisplayName`; `nil` when it has none
    public var title: String?

    public init(job: String, label: String, title: String?) {
        self.job = job
        self.label = label
        self.title = title
    }
}

/// Why Watch a Build… doesn't watch what it got, with the sheet's copy (WATCH-02, WATCH-03). Nothing is stored.
public enum WatchRefusal: Error, Hashable, Sendable, CustomStringConvertible {
    /// a GitLab link into another project than the team's
    case otherProject(String)
    /// a GitLab link of the team's project that isn't a merge request, like a pipeline
    case notAMergeRequest
    /// a link that is neither the team's GitLab nor under its Jenkins job
    case otherJenkins(jobURL: String)
    /// neither a link nor a number, like an empty text or a branch name
    case notUnderstood
    /// Jenkins answered 404 for the job
    case noJob(job: String)
    /// no token, missing team values, or another Jenkins problem (JERR)
    case problem(Problem)
    /// one of my jobs, which shows with my builds anyway (WATCH-03)
    case mine(job: String)

    /// the text the sheet shows, without a trailing period (WATCH-03)
    public var message: String {
        switch self {
        case .otherProject(let project): "That is not in \(project), the GitLab project in Team"
        case .notAMergeRequest: "That GitLab link is not a merge request"
        case .otherJenkins(let jobURL): "That is not a link into the Jenkins job in Team, \(jobURL)"
        case .notUnderstood: "Paste a link to a Jenkins build or a GitLab merge request, or !123"
        case .noJob(let job): "Jenkins has no job \(Build.label(forJob: job))"
        case .problem(let problem): problem.message
        case .mine(let job): "\(Build.label(forJob: job)) is yours: it shows with your builds anyway"
        }
    }

    public var description: String { message }
}

extension WatchRefusal: LocalizedError {
    public var errorDescription: String? { message }
}
