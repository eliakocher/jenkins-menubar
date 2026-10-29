import Foundation

/// The status badge of a merge request: the first rule of MR-02 that matches, as text, an SF Symbol and GitLab's
/// colors. Values only: MenubarUI turns them into an `Image` and a `Color`.
public struct MergeRequestStatus: Hashable, Sendable {
    public var kind: Kind
    /// the badge's text, like "Pipeline failed"
    public var text: String
    /// the SF Symbol's name; every badge is round, so the titles line up
    public var symbol: String
    public var color: Color

    public init(kind: Kind, text: String, symbol: String, color: Color) {
        self.kind = kind
        self.text = text
        self.symbol = symbol
        self.color = color
    }

    /// Which rule of MR-02 matched.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case readyToMerge
        case draft
        case pipelineFailed
        case conflicts
        case needsRebase
        case changesRequested
        case notApproved
        case unresolvedThreads
        case pipelineRunning
        case checking
        /// any other status, shown in words
        case other
        /// in Review requested, around the status
        case reviewRequested
    }

    /// One of GitLab's colors, as hex text for the light and the dark appearance.
    public struct Color: Hashable, Sendable {
        /// like `#108548`
        public var light: String
        /// like `#52B87A`
        public var dark: String

        public init(light: String, dark: String) {
            self.light = light
            self.dark = dark
        }

        public static let green = Color(light: "#108548", dark: "#52B87A")
        public static let neutral = Color(light: "#737278", dark: "#A4A3A8")
        public static let orange = Color(light: "#C17D10", dark: "#D99530")
        public static let red = Color(light: "#DD2B0E", dark: "#EC5941")
        public static let blue = Color(light: "#1F75CB", dark: "#428FDC")
    }

    /// Returns the badge of a merge request as it shows for me: in Review requested, "Review requested · <status>"
    /// with an eye in orange, otherwise the status (MR-02).
    ///
    /// - Parameters:
    ///   - mergeRequest: the merge request
    ///   - me: my GitLab username
    /// - Returns: the badge
    public static func of(_ mergeRequest: MergeRequest, me: String) -> MergeRequestStatus {
        let status = of(mergeRequest)
        guard mergeRequest.isReviewRequested(of: me) else { return status }
        return MergeRequestStatus(kind: .reviewRequested, text: "Review requested · \(status.text)", symbol: "eye.circle.fill",
                                  color: .orange)
    }

    /// Returns the status of a merge request: the first rule of MR-02 that matches, in the old tool's order.
    ///
    /// - Parameter mergeRequest: the merge request
    /// - Returns: the badge, whoever looks at it
    public static func of(_ mergeRequest: MergeRequest) -> MergeRequestStatus {
        let status = mergeRequest.mergeStatus
        return if status == .mergeable {
            MergeRequestStatus(kind: .readyToMerge, text: "Ready to merge", symbol: "checkmark.circle.fill", color: .green)
        } else if mergeRequest.isDraft {
            MergeRequestStatus(kind: .draft, text: "Draft", symbol: "pencil.circle.fill", color: .neutral)
        } else if mergeRequest.pipelineStatus == .failed {
            MergeRequestStatus(kind: .pipelineFailed, text: "Pipeline failed", symbol: "xmark.circle.fill", color: .red)
        } else if status == .conflict {
            MergeRequestStatus(kind: .conflicts, text: "Merge conflicts", symbol: "exclamationmark.circle.fill", color: .red)
        } else if status == .needRebase {
            MergeRequestStatus(kind: .needsRebase, text: "Needs a rebase", symbol: "arrow.up.circle.fill", color: .orange)
        } else if status == .requestedChanges {
            MergeRequestStatus(kind: .changesRequested, text: "Changes requested", symbol: "exclamationmark.circle.fill",
                               color: .orange)
        } else if status == .notApproved {
            MergeRequestStatus(kind: .notApproved, text: approvals(of: mergeRequest), symbol: "hourglass.circle.fill",
                               color: .neutral)
        } else if status == .discussionsNotResolved {
            MergeRequestStatus(kind: .unresolvedThreads, text: "Unresolved threads", symbol: "bubble.left.circle.fill",
                               color: .orange)
        } else if status == .ciStillRunning {
            MergeRequestStatus(kind: .pipelineRunning, text: "Pipeline running", symbol: "arrow.triangle.2.circlepath.circle.fill",
                               color: .blue)
        } else if let status, [.unchecked, .checking, .preparing, .approvalsSyncing].contains(status) {
            MergeRequestStatus(kind: .checking, text: "Checking mergeability", symbol: "ellipsis.circle.fill", color: .neutral)
        } else {
            MergeRequestStatus(kind: .other, text: (status?.rawValue ?? "unknown").lowercased().replacingOccurrences(of: "_", with: " "),
                               symbol: "questionmark.circle.fill", color: .neutral)
        }
    }

    /// Returns the approvals text, counted over the reviewers rather than GitLab's approval rules, which add every
    /// code owner rule up (MR-02).
    ///
    /// - Parameter mergeRequest: the merge request
    /// - Returns: "No reviewers yet", "All reviewers approved, approval rules still open" or "Missing M of N approvals"
    public static func approvals(of mergeRequest: MergeRequest) -> String {
        let reviewers = mergeRequest.reviewers.count
        let missing = mergeRequest.reviewers.filter { !$0.approved }.count
        return if reviewers == 0 {
            "No reviewers yet"
        } else if missing == 0 {
            "All reviewers approved, approval rules still open"
        } else {
            "Missing \(missing) of \(reviewers) approval\(reviewers == 1 ? "" : "s")"
        }
    }
}

extension MergeRequest {
    /// Returns whether my review is still asked of me, which puts the MR in Review requested (MR-01).
    ///
    /// - Parameter username: my GitLab username
    /// - Returns: `true` when GitLab asked me to review it and my review state is still pending
    public func isReviewRequested(of username: String) -> Bool {
        roles.contains(.reviewRequested) && reviewState(of: username).isPending
    }
}
