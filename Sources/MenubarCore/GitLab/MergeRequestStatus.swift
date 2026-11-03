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
        /// merged (MR-17), whoever looks at it
        case merged
    }

    /// One of GitLab's colors, as hex text for the light and the dark appearance.
    public struct Color: Codable, Hashable, Sendable {
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
        /// GitLab's color of a merged MR
        public static let purple = Color(light: "#6666C4", dark: "#9D9DE0")
    }

    /// Returns the badge of a merge request as it shows for me: in Review requested, "Review requested · <status>"
    /// with an eye in orange, otherwise the status (MR-02).
    ///
    /// - Parameters:
    ///   - mergeRequest: the merge request
    ///   - me: my GitLab username
    ///   - saysPipeline: whether the badge may speak of the pipeline; `false` while the header shows the Jenkins build's
    ///     chip, so the pipeline isn't told twice (MR-14). Then a status that is only about the pipeline ("Pipeline
    ///     failed", "Pipeline running") leaves its place: "Review requested" stands alone, and any other badge reads the
    ///     review state, "Missing 1 of 2 approvals".
    /// - Returns: the badge
    public static func of(_ mergeRequest: MergeRequest, me: String, saysPipeline: Bool = true) -> MergeRequestStatus {
        if mergeRequest.mergedAt != nil {
            return merged
        }
        let status = rule(of: mergeRequest, saysPipeline: saysPipeline)
        guard mergeRequest.isReviewRequested(of: me) else {
            return status ?? reviewState(of: mergeRequest)
        }
        return MergeRequestStatus(
            kind: .reviewRequested, text: status.map { "Review requested · \($0.text)" } ?? "Review requested",
            symbol: "eye.circle.fill", color: .orange)
    }

    /// Returns the status of a merge request: the first rule of MR-02 that matches, in the old tool's order.
    ///
    /// - Parameter mergeRequest: the merge request
    /// - Returns: the badge, whoever looks at it
    public static func of(_ mergeRequest: MergeRequest) -> MergeRequestStatus {
        if mergeRequest.mergedAt != nil {
            return merged
        }
        // Every rule may answer, so the fallback is never used.
        return rule(of: mergeRequest, saysPipeline: true) ?? reviewState(of: mergeRequest)
    }

    /// the badge of a merged MR (MR-17)
    public static let merged = MergeRequestStatus(kind: .merged, text: "Merged", symbol: "arrow.triangle.merge", color: .purple)

    /// Returns whether a badge's text is about the pipeline: "Pipeline failed", also behind "Review requested · ".
    ///
    /// - Parameter text: the badge's text
    /// - Returns: `true` when its last part starts with "Pipeline"
    public static func textNamesPipeline(_ text: String) -> Bool {
        text.components(separatedBy: " · ").last?.hasPrefix("Pipeline") == true
    }

    /// The badge for a merge request whose status is only about the pipeline, from its reviewers.
    private static func reviewState(of mergeRequest: MergeRequest) -> MergeRequestStatus {
        let reviewers = mergeRequest.reviewers
        let allApproved = !reviewers.isEmpty && reviewers.allSatisfy(\.approved)
        return MergeRequestStatus(
            kind: .notApproved, text: allApproved ? "All reviewers approved" : approvals(of: mergeRequest),
            symbol: "hourglass.circle.fill", color: .neutral)
    }

    /// The first rule that matches. Without `saysPipeline`, the rules about the pipeline are skipped, and `nil` comes
    /// back when nothing else is left to say, which GitLab's CI_MUST_PASS is.
    private static func rule(of mergeRequest: MergeRequest, saysPipeline: Bool) -> MergeRequestStatus? {
        let status = mergeRequest.mergeStatus
        let ciMustPass = status == MergeRequest.MergeStatus(rawValue: "CI_MUST_PASS")
        return if status == .mergeable {
            MergeRequestStatus(kind: .readyToMerge, text: "Ready to merge", symbol: "checkmark.circle.fill", color: .green)
        } else if mergeRequest.isDraft {
            MergeRequestStatus(kind: .draft, text: "Draft", symbol: "pencil.circle.fill", color: .neutral)
        } else if saysPipeline, mergeRequest.pipelineStatus == .failed {
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
            saysPipeline
                ? MergeRequestStatus(kind: .pipelineRunning, text: "Pipeline running",
                                     symbol: "arrow.triangle.2.circlepath.circle.fill", color: .blue)
                : nil
        } else if !saysPipeline, ciMustPass {
            nil
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
