import Foundation

/// One Jenkins multibranch job and the GitLab project it builds, with the team's conventions.
///
/// The first project is the primary one; the others watch more jobs on the same Jenkins and GitLab (plan Phase 13).
public struct Project: Codable, Hashable, Identifiable, Sendable {
    public var id: ProjectID
    public var team: TeamValues

    public init(id: ProjectID, team: TeamValues) {
        self.id = id
        self.team = team
    }

    /// the project's short name: the last part of its GitLab path, like `project`; "Project" while the path is empty
    public var shortName: String {
        let path = team.gitLabProject.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return path.split(separator: "/").last.map(String.init) ?? "Project"
    }

    /// Returns the names the views and the alerts show: the short name, or the full GitLab path when two projects
    /// share their short name (PROJ-01).
    ///
    /// - Parameter projects: the projects
    /// - Returns: each project's name
    public static func names(of projects: [Project]) -> [ProjectID: String] {
        var names: [ProjectID: String] = [:]
        for project in projects {
            let shared = projects.count { $0.shortName == project.shortName } > 1
            names[project.id] = shared && !project.team.gitLabProject.isEmpty ? project.team.gitLabProject : project.shortName
        }
        return names
    }
}

/// Why a project can't be added, changed or removed (PROJ-02).
public enum ProjectError: Error, Hashable, Sendable, LocalizedError {
    /// a required team value is empty or not a web URL
    case incomplete
    /// another project watches the same Jenkins job, by its name
    case sameJob(String)
    /// the Jenkins job is on another server than the primary project's
    case otherJenkins(String)
    /// the GitLab URL isn't the primary project's
    case otherGitLab(String)
    /// the primary project can't be removed
    case primary

    /// the text Settings shows
    public var message: String {
        switch self {
        case .incomplete: "Fill in the Jenkins job, the GitLab URL and the GitLab project"
        case .sameJob(let name): "\(name) watches that Jenkins job already"
        case .otherJenkins(let name): "Uses another Jenkins than \(name): the Jenkins token is for one server"
        case .otherGitLab(let name): "Uses another GitLab than \(name): the GitLab token is for one server"
        case .primary: "The first project can't be removed; change its values instead"
        }
    }

    public var errorDescription: String? { message }

    /// Returns why values can't be a project next to others: one token per server means one Jenkins and one GitLab
    /// for all projects, the primary project's (the user's decision on 2026-10-29).
    ///
    /// - Parameters:
    ///   - team: the new values, normalized
    ///   - others: the other projects, the primary first
    /// - Returns: the refusal; `nil` when the values fit
    public static func refusal(of team: TeamValues, among others: [Project]) -> ProjectError? {
        guard team.missing.isEmpty, let job = team.jenkinsJob, let gitLab = team.gitLab else {
            return .incomplete
        }
        let names = Project.names(of: others)
        if let same = others.first(where: { $0.team.jenkinsJob.map(TeamValues.sameJob(job)) ?? false }) {
            return .sameJob(names[same.id] ?? same.shortName)
        }
        guard let primary = others.first else {
            return nil
        }
        let name = names[primary.id] ?? primary.shortName
        if let primaryJob = primary.team.jenkinsJob, TeamValues.server(of: primaryJob) != TeamValues.server(of: job) {
            return .otherJenkins(name)
        }
        if let primaryGitLab = primary.team.gitLab, TeamValues.server(of: primaryGitLab) != TeamValues.server(of: gitLab) {
            return .otherGitLab(name)
        }
        return nil
    }
}

/// The values a team shares, edited in Settings → Team and passed around in a team file. Never a token.
///
/// The values are kept as typed (after ``normalized()``), so a job URL keeps its `%20` and `%252F` as Jenkins shows
/// them. An empty value means not set; the last three are optional and empty turns them off.
public struct TeamValues: Codable, Hashable, Sendable {
    /// the Jenkins multibranch job that builds the GitLab project, as shown in the browser; its MR builds are
    /// `<jenkinsJobURL>/job/MR-<iid>`
    public var jenkinsJobURL: String
    /// the GitLab instance, like `https://gitlab.example.com`
    public var gitLabURL: String
    /// the project's full path in GitLab, like `group/subgroup/project`
    public var gitLabProject: String
    /// the label of work items that get their own Committed section (WI-01)
    public var committedLabel: String
    /// the prefix of the scoped label whose value shows before a work item's title, like `slot::` (WI-04)
    public var slotLabelPrefix: String
    /// the title prefix of merge requests that don't count as work on a work item, like `[cascade]` (WI-05)
    public var ignoredMergeRequestPrefix: String
    /// the scope of the labels that give a work item its type, like `type::`: the new work item pages add
    /// `<prefix>Bug` (NEW-02)
    public var typeLabelPrefix: String
    /// the weekday of a slot's release, in its ISO week: a name like `Monday` or a number from 1 (Monday) to 7; empty
    /// means Monday (SLOT-01)
    public var slotReleaseWeekday: String
    /// how many days before the release the code freeze is; empty means 14 (SLOT-01)
    public var slotCodeFreezeDays: String
    /// how many days before the release early access starts; empty means 7 (SLOT-01)
    public var slotEarlyAccessDays: String
    /// how many days before the code freeze a committed work item without a merge request is flagged, and the slot
    /// alert comes; empty means 3 (SLOT-04)
    public var slotWarnDays: String
    /// the label of a work item that is being worked on, like `status::InProgress`; empty finds a label whose value is
    /// "in progress" (SLOT-03)
    public var inProgressLabel: String
    /// the web page of the team's slot planning tool, which Slots opens; empty hides the link (SLOT-05)
    public var slotPlanningURL: String

    public init(
        jenkinsJobURL: String = "",
        gitLabURL: String = "",
        gitLabProject: String = "",
        committedLabel: String = "",
        slotLabelPrefix: String = "",
        ignoredMergeRequestPrefix: String = "",
        typeLabelPrefix: String = "",
        slotReleaseWeekday: String = "",
        slotCodeFreezeDays: String = "",
        slotEarlyAccessDays: String = "",
        slotWarnDays: String = "",
        inProgressLabel: String = "",
        slotPlanningURL: String = ""
    ) {
        self.jenkinsJobURL = jenkinsJobURL
        self.gitLabURL = gitLabURL
        self.gitLabProject = gitLabProject
        self.committedLabel = committedLabel
        self.slotLabelPrefix = slotLabelPrefix
        self.ignoredMergeRequestPrefix = ignoredMergeRequestPrefix
        self.typeLabelPrefix = typeLabelPrefix
        self.slotReleaseWeekday = slotReleaseWeekday
        self.slotCodeFreezeDays = slotCodeFreezeDays
        self.slotEarlyAccessDays = slotEarlyAccessDays
        self.slotWarnDays = slotWarnDays
        self.inProgressLabel = inProgressLabel
        self.slotPlanningURL = slotPlanningURL
    }

    /// A missing value reads as empty, so a team file from an older or newer app still reads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        self.init()
        for key in Key.allCases {
            self[key] = try container.decodeIfPresent(String.self, forKey: key) ?? ""
        }
    }

    /// The names of the values, as the logs and the team file call them.
    public enum Key: String, CaseIterable, CodingKey, Sendable {
        case jenkinsJobURL
        case gitLabURL
        case gitLabProject
        case committedLabel
        case slotLabelPrefix
        case ignoredMergeRequestPrefix
        case typeLabelPrefix
        case slotReleaseWeekday
        case slotCodeFreezeDays
        case slotEarlyAccessDays
        case slotWarnDays
        case inProgressLabel
        case slotPlanningURL

        /// whether the app can't check anything without this value (TEAM-03)
        public var isRequired: Bool {
            switch self {
            case .jenkinsJobURL, .gitLabURL, .gitLabProject: true
            case .committedLabel, .slotLabelPrefix, .ignoredMergeRequestPrefix, .typeLabelPrefix, .slotReleaseWeekday,
                .slotCodeFreezeDays, .slotEarlyAccessDays, .slotWarnDays, .inProgressLabel, .slotPlanningURL: false
            }
        }
    }

    public subscript(key: Key) -> String {
        get {
            switch key {
            case .jenkinsJobURL: jenkinsJobURL
            case .gitLabURL: gitLabURL
            case .gitLabProject: gitLabProject
            case .committedLabel: committedLabel
            case .slotLabelPrefix: slotLabelPrefix
            case .ignoredMergeRequestPrefix: ignoredMergeRequestPrefix
            case .typeLabelPrefix: typeLabelPrefix
            case .slotReleaseWeekday: slotReleaseWeekday
            case .slotCodeFreezeDays: slotCodeFreezeDays
            case .slotEarlyAccessDays: slotEarlyAccessDays
            case .slotWarnDays: slotWarnDays
            case .inProgressLabel: inProgressLabel
            case .slotPlanningURL: slotPlanningURL
            }
        }
        set {
            switch key {
            case .jenkinsJobURL: jenkinsJobURL = newValue
            case .gitLabURL: gitLabURL = newValue
            case .gitLabProject: gitLabProject = newValue
            case .committedLabel: committedLabel = newValue
            case .slotLabelPrefix: slotLabelPrefix = newValue
            case .ignoredMergeRequestPrefix: ignoredMergeRequestPrefix = newValue
            case .typeLabelPrefix: typeLabelPrefix = newValue
            case .slotReleaseWeekday: slotReleaseWeekday = newValue
            case .slotCodeFreezeDays: slotCodeFreezeDays = newValue
            case .slotEarlyAccessDays: slotEarlyAccessDays = newValue
            case .slotWarnDays: slotWarnDays = newValue
            case .inProgressLabel: inProgressLabel = newValue
            case .slotPlanningURL: slotPlanningURL = newValue
            }
        }
    }

    /// the required values that are empty, in the order of ``Key``; empty when the app can check (TEAM-03)
    public var missing: [Key] {
        Key.allCases.filter { $0.isRequired && self[$0].isEmpty }
    }

    /// Returns the values as TEAM-01 saves them: spaces around trimmed, and the URLs without a trailing `/`.
    ///
    /// - Returns: the normalized values
    public func normalized() -> TeamValues {
        var values = self
        for key in Key.allCases {
            values[key] = values[key].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for key in [Key.jenkinsJobURL, .gitLabURL] {
            while values[key].hasSuffix("/") {
                values[key].removeLast()
            }
        }
        return values
    }

    /// the slot planning tool's page, when it is an `http` or `https` URL with a host
    public var slotPlanning: URL? {
        Self.webURL(slotPlanningURL)
    }

    /// the Jenkins job URL, when it is an `http` or `https` URL with a host
    public var jenkinsJob: URL? {
        Self.webURL(jenkinsJobURL)
    }

    /// the GitLab URL, when it is an `http` or `https` URL with a host
    public var gitLab: URL? {
        Self.webURL(gitLabURL)
    }

    /// Returns a URL's server, `scheme://host:port` in lowercase, which a token belongs to.
    ///
    /// - Parameter url: the URL
    /// - Returns: the server
    static func server(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? (scheme == "http" ? 80 : 443)
        return "\(scheme)://\(url.host()?.lowercased() ?? ""):\(port)"
    }

    /// Returns whether two job URLs name the same job: the same server and path, `%2F` and its doubled form alike.
    static func sameJob(_ job: URL) -> (URL) -> Bool {
        { other in
            server(of: job) == server(of: other) && canonicalPath(job) == canonicalPath(other)
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.path(percentEncoded: true).lowercased().replacingOccurrences(of: "%252f", with: "%2f")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            url.host() != nil
        else { return nil }
        return url
    }
}
