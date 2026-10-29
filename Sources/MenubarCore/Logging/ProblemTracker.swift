import Foundation

/// Logs a problem once when it starts, again when its text changes, and once when it is resolved; not on every check
/// (LOG-01).
///
/// Each check or load reports its problem, or nil, under a key of its own, such as `jenkins`, `gitlab.mergeRequests`
/// or `gitlab.workItems`, so the problem of one doesn't resolve another's.
public actor ProblemTracker {
    private let log: ActivityLog
    private var current: [String: (problem: Problem, source: ActivityEntry.Source)] = [:]

    /// - Parameters:
    ///   - log: where the problems are logged
    ///   - current: the problems the caches still had at launch, so they aren't logged again as new
    public init(log: ActivityLog, current: [String: (Problem, ActivityEntry.Source)] = [:]) {
        self.log = log
        self.current = current.mapValues { (problem: $0.0, source: $0.1) }
    }

    /// The problem the key has now, or nil.
    public func problem(_ key: String) -> Problem? {
        current[key]?.problem
    }

    /// Forgets a key's problem without logging it as resolved, as for a project that was removed (PROJ-02).
    ///
    /// - Parameter key: the key
    public func forget(_ key: String) {
        current[key] = nil
    }

    /// Notes what the check under `key` found: a problem, or nil when it went fine.
    ///
    /// A new problem, or one whose text changed, is logged as an error with the outcome `failed:PROBLEM`. When the
    /// problem is gone, "Resolved: <its text>" is logged as info, with `ok:RESOLVED`, under the source it was logged
    /// with.
    public func update(_ key: String, to problem: Problem?, source: ActivityEntry.Source) async {
        let previous = current[key]
        guard let problem else {
            if let previous {
                current[key] = nil
                await log.log(.info, previous.source, "Resolved: \(previous.problem.message)", outcome: .ok("RESOLVED"))
            }
            return
        }
        current[key] = (problem, source)
        if previous?.problem.message != problem.message {
            await log.log(.error, source, problem.message, outcome: .failed("PROBLEM"))
        }
    }
}
