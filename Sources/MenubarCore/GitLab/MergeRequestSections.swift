import Foundation

/// My open merge requests in the three sections of MR-01, each newest first.
public struct MergeRequestSections: Hashable, Sendable {
    /// "My Merge Requests": authored and assigned, without those in Review Requested
    public var yours: [MergeRequest]
    /// "Review Requested": my review is still pending
    public var reviewRequested: [MergeRequest]
    /// "Reviewed": the other MRs whose review was asked of me
    public var reviewed: [MergeRequest]

    /// the text when all three sections are empty
    public static let emptyText = "No open merge requests"

    /// Sorts merge requests into the sections.
    ///
    /// - Parameters:
    ///   - mergeRequests: the MRs, each once with all its roles, as ``MergeRequestList`` holds them
    ///   - me: my GitLab username
    public init(_ mergeRequests: [MergeRequest], me: String) {
        let newestFirst = mergeRequests.sorted { ($0.updatedAt, $0.iid) > ($1.updatedAt, $1.iid) }
        reviewRequested = newestFirst.filter { $0.isReviewRequested(of: me) }
        yours = newestFirst.filter {
            !$0.roles.isDisjoint(with: [.authored, .assigned]) && !$0.isReviewRequested(of: me)
        }
        let shown = Set((yours + reviewRequested).map(\.id))
        reviewed = newestFirst.filter { $0.roles.contains(.reviewRequested) && !shown.contains($0.id) }
    }

    /// One section, with its title.
    public struct Section: Hashable, Sendable, Identifiable {
        public var kind: Kind
        public var mergeRequests: [MergeRequest]

        public init(kind: Kind, mergeRequests: [MergeRequest]) {
            self.kind = kind
            self.mergeRequests = mergeRequests
        }

        public var id: Kind { kind }

        /// the section's title, like "Review Requested"
        public var title: String { kind.title }
    }

    /// The three sections, in their order.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case yours
        case reviewRequested
        case reviewed

        public var title: String {
            switch self {
            case .yours: "My Merge Requests"
            case .reviewRequested: "Review Requested"
            case .reviewed: "Reviewed"
            }
        }
    }

    /// the sections that have merge requests, in their order; empty sections are left out
    public var sections: [Section] {
        [Section(kind: .yours, mergeRequests: yours), Section(kind: .reviewRequested, mergeRequests: reviewRequested),
         Section(kind: .reviewed, mergeRequests: reviewed)]
            .filter { !$0.mergeRequests.isEmpty }
    }

    /// whether all three sections are empty, which shows ``emptyText``
    public var isEmpty: Bool { sections.isEmpty }

    /// "Merge Requests · 2 open · 1 to review": the open count is My Merge Requests, the review count is Review
    /// Requested, and a count of 0 is left out
    public var header: String {
        var parts = ["Merge Requests"]
        if !yours.isEmpty {
            parts.append("\(yours.count) open")
        }
        if !reviewRequested.isEmpty {
            parts.append("\(reviewRequested.count) to review")
        }
        return parts.joined(separator: " · ")
    }
}

extension MergeRequest {
    /// Returns the short reference: "!12" in the project, "<last path segment>!12" in another one (MR-03).
    ///
    /// - Parameter project: the team's project path, like `group/project`
    /// - Returns: the short reference
    public func shortReference(project: String) -> String {
        GitLabText.shortReference(reference, project: project)
    }

    /// Returns the details of the MR, joined with " · ": the short reference, the badge text, "by <author>" when it
    /// isn't mine, "updated 5m ago", "3 files +10 −2", and "pipeline success" when there is a pipeline (MR-03).
    ///
    /// - Parameters:
    ///   - me: my GitLab username
    ///   - project: the team's project path
    ///   - now: the time to count the age from
    /// - Returns: the details, the row's tooltip in the panel and its detail in the window
    public func details(me: String, project: String, now: Date) -> String {
        var parts = [shortReference(project: project), MergeRequestStatus.of(self, me: me).text]
        if author.username != me, !author.name.isEmpty {
            parts.append("by \(author.name)")
        }
        parts.append("updated \(GitLabText.age(since: updatedAt, now: now)) ago")
        let stats = diffStats ?? DiffStats(additions: 0, deletions: 0, fileCount: 0)
        parts.append("\(stats.fileCount) file\(stats.fileCount == 1 ? "" : "s") +\(stats.additions) −\(stats.deletions)")
        if let pipelineStatus {
            parts.append("pipeline \(pipelineStatus.rawValue.lowercased())")
        }
        return parts.joined(separator: " · ")
    }
}

/// Text rules that merge requests and work items share.
public enum GitLabText {
    /// Returns "Last checked HH:MM": the time of a section's last GitLab load, in the user's short time format (WI-07).
    ///
    /// - Parameters:
    ///   - date: the time of the last load, like ``MergeRequestsStore/lastLoadAt``
    ///   - locale: the locale of the time format
    ///   - timeZone: the time zone of the time
    /// - Returns: like "Last checked 14:05"
    public static func lastChecked(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        "Last checked " + Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone).format(date)
    }

    /// Returns an age in whole minutes under an hour ("5m"), whole hours under a day ("3h"), whole days otherwise
    /// ("2d"), as PIPE-03 counts it.
    ///
    /// - Parameters:
    ///   - date: when it happened
    ///   - now: the time to count from
    /// - Returns: the age, never below "0m"
    public static func age(since date: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        return if seconds < 3600 {
            "\(seconds / 60)m"
        } else if seconds < 86400 {
            "\(seconds / 3600)h"
        } else {
            "\(seconds / 86400)d"
        }
    }

    /// Returns the short form of a full reference like `group/project!12`, `group/project#12` or `group&3`: the sign
    /// and iid in the project, with the last path segment before them in another one.
    ///
    /// - Parameters:
    ///   - reference: the full reference
    ///   - project: the team's project path
    /// - Returns: like "!12", "other!12" or "#12"; the reference itself when it has no iid at its end
    public static func shortReference(_ reference: String, project: String) -> String {
        guard let sign = reference.lastIndex(where: { "!#&".contains($0) }) else { return reference }
        let iid = reference[reference.index(after: sign)...]
        guard !iid.isEmpty, iid.allSatisfy({ $0.isASCII && $0.isNumber }) else { return reference }
        let path = reference[..<sign]
        let suffix = String(reference[sign...])
        return path == project ? suffix : (path.split(separator: "/").last.map(String.init) ?? "") + suffix
    }
}
