import Foundation

/// A rebuild started from the app, from the click until the new build shows, or until it failed (PIPE-09).
///
/// The Pipelines store keeps one per job; the build's row reads "Rebuilding…", with Cancel while the new build waits
/// in Jenkins's queue, or the failure's plain text.
public struct JenkinsRebuild: Hashable, Sendable {
    /// Where the rebuild stands.
    public enum Phase: Hashable, Sendable {
        /// the requests that start the job are on their way
        case starting
        /// the new build waits in Jenkins's queue; Cancel removes it
        case queued(QueueItem)
        /// the new build has its number; the next check shows it
        case started(number: Int)
        /// the rebuild didn't start: the plain text
        case failed(String)
    }

    /// the build started again
    public var build: BuildID
    public var phase: Phase

    public init(build: BuildID, phase: Phase) {
        self.build = build
        self.phase = phase
    }

    /// the row's text while the rebuild is under way
    public static let rebuildingText = "Rebuilding…"

    /// "Rebuilding…" while under way, the failure's text once failed
    public var text: String {
        failure ?? Self.rebuildingText
    }

    /// the failure's text; `nil` unless the rebuild failed
    public var failure: String? {
        if case .failed(let message) = phase { message } else { nil }
    }

    /// whether Cancel shows: while the new build waits in the queue
    public var canCancel: Bool {
        if case .queued = phase { true } else { false }
    }

    /// whether the rebuild is under way, so that another click starts nothing until it ends
    public var isUnderWay: Bool {
        failure == nil
    }
}
