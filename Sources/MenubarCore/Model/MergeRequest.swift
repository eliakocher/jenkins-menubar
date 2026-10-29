import Foundation

/// An open GitLab merge request of mine, or one whose review is asked of me (MR-01).
///
/// Taken from the MergeRequests query: `iid title webUrl draft reference(full: true) updatedAt detailedMergeStatus
/// author { username name } headPipeline { status } diffStatsSummary { additions deletions fileCount }
/// reviewers { nodes { username name mergeRequestInteraction { reviewState approved } } }`.
public struct MergeRequest: Codable, Hashable, Identifiable, Sendable {
    public var iid: Int
    public var title: String
    public var webURL: URL
    /// the full reference, like `group/project!12`
    public var reference: String
    public var isDraft: Bool
    /// GitLab's `detailedMergeStatus`; `nil` when GitLab sends none
    public var mergeStatus: MergeStatus?
    public var author: Person
    public var reviewers: [Reviewer]
    /// the head pipeline's status; `nil` without a pipeline
    public var pipelineStatus: PipelineStatus?
    /// `nil` when GitLab sends no stats
    public var diffStats: DiffStats?
    public var updatedAt: Date
    /// how the MR is mine; an MR can be authored and assigned at once
    public var roles: Set<Role>
    /// the branch it merges, which leads a workspace's checkout to its MR (WS-04); `nil` in a cache from before it was
    /// asked for
    public var sourceBranch: String?

    public init(
        iid: Int,
        title: String,
        webURL: URL,
        reference: String,
        isDraft: Bool = false,
        mergeStatus: MergeStatus? = nil,
        author: Person,
        reviewers: [Reviewer] = [],
        pipelineStatus: PipelineStatus? = nil,
        diffStats: DiffStats? = nil,
        updatedAt: Date,
        roles: Set<Role>,
        sourceBranch: String? = nil
    ) {
        self.sourceBranch = sourceBranch
        self.iid = iid
        self.title = title
        self.webURL = webURL
        self.reference = reference
        self.isDraft = isDraft
        self.mergeStatus = mergeStatus
        self.author = author
        self.reviewers = reviewers
        self.pipelineStatus = pipelineStatus
        self.diffStats = diffStats
        self.updatedAt = updatedAt
        self.roles = roles
    }

    /// The same MR shows once, by its URL (MR-01).
    public var id: URL { webURL }

    /// Returns my review state: the state of the reviewer with my username, or unreviewed when I'm not among the
    /// reviewers (MR-01).
    ///
    /// - Parameter username: my GitLab username
    /// - Returns: the review state
    public func reviewState(of username: String) -> ReviewState {
        reviewers.first { $0.username == username }?.reviewState ?? .unreviewed
    }

    /// How a merge request is mine.
    public enum Role: String, Codable, Hashable, Sendable, CaseIterable {
        case authored
        case assigned
        case reviewRequested
    }

    /// A GitLab user, as a merge request names them.
    public struct Person: Codable, Hashable, Sendable {
        public var username: String
        /// the display name
        public var name: String

        public init(username: String, name: String) {
            self.username = username
            self.name = name
        }
    }

    /// A reviewer of a merge request, with their review.
    public struct Reviewer: Codable, Hashable, Sendable {
        public var username: String
        /// the full name, as the MR detail shows it (WIN-02); empty when GitLab sent none
        public var name: String
        /// `mergeRequestInteraction.reviewState`
        public var reviewState: ReviewState
        /// `mergeRequestInteraction.approved`
        public var approved: Bool

        public init(username: String, name: String = "", reviewState: ReviewState, approved: Bool) {
            self.username = username
            self.name = name
            self.reviewState = reviewState
            self.approved = approved
        }

        private enum CodingKeys: String, CodingKey {
            case username, name, reviewState, approved
        }

        // A reviewer cached before the name was asked for decodes with an empty one.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                username: try container.decode(String.self, forKey: .username),
                name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
                reviewState: try container.decode(ReviewState.self, forKey: .reviewState),
                approved: try container.decode(Bool.self, forKey: .approved))
        }
    }

    /// The added and deleted lines and the changed files of a merge request.
    public struct DiffStats: Codable, Hashable, Sendable {
        public var additions: Int
        public var deletions: Int
        public var fileCount: Int

        public init(additions: Int, deletions: Int, fileCount: Int) {
            self.additions = additions
            self.deletions = deletions
            self.fileCount = fileCount
        }
    }

    /// GitLab's `DetailedMergeStatus`. The ones MR-02 names have constants; others are kept as they come.
    public struct MergeStatus: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        /// GitLab's enum value, like `NOT_APPROVED`
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let mergeable = MergeStatus(rawValue: "MERGEABLE")
        public static let conflict = MergeStatus(rawValue: "CONFLICT")
        public static let needRebase = MergeStatus(rawValue: "NEED_REBASE")
        public static let requestedChanges = MergeStatus(rawValue: "REQUESTED_CHANGES")
        public static let notApproved = MergeStatus(rawValue: "NOT_APPROVED")
        public static let discussionsNotResolved = MergeStatus(rawValue: "DISCUSSIONS_NOT_RESOLVED")
        public static let ciStillRunning = MergeStatus(rawValue: "CI_STILL_RUNNING")
        public static let unchecked = MergeStatus(rawValue: "UNCHECKED")
        public static let checking = MergeStatus(rawValue: "CHECKING")
        public static let preparing = MergeStatus(rawValue: "PREPARING")
        public static let approvalsSyncing = MergeStatus(rawValue: "APPROVALS_SYNCING")
        public static let draftStatus = MergeStatus(rawValue: "DRAFT_STATUS")

        public var description: String { rawValue }
    }

    /// GitLab's `MergeRequestReviewState`. Others are kept as they come.
    public struct ReviewState: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        /// GitLab's enum value, like `REVIEW_STARTED`
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let unreviewed = ReviewState(rawValue: "UNREVIEWED")
        public static let reviewStarted = ReviewState(rawValue: "REVIEW_STARTED")
        public static let reviewed = ReviewState(rawValue: "REVIEWED")
        public static let requestedChanges = ReviewState(rawValue: "REQUESTED_CHANGES")
        public static let approved = ReviewState(rawValue: "APPROVED")
        public static let unapproved = ReviewState(rawValue: "UNAPPROVED")

        /// whether a review in this state is still asked of me, which puts the MR in Review requested (MR-01)
        public var isPending: Bool {
            self == .unreviewed || self == .reviewStarted || self == .unapproved
        }

        public var description: String { rawValue }
    }

    /// GitLab's `PipelineStatusEnum`. Others are kept as they come.
    public struct PipelineStatus: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        /// GitLab's enum value, like `RUNNING`
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let running = PipelineStatus(rawValue: "RUNNING")
        public static let failed = PipelineStatus(rawValue: "FAILED")
        public static let success = PipelineStatus(rawValue: "SUCCESS")
        public static let canceled = PipelineStatus(rawValue: "CANCELED")

        public var description: String { rawValue }
    }
}
