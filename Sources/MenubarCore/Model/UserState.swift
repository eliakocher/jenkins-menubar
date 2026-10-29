import Foundation

/// What the user chose for one project: the watched jobs and the hidden builds.
public struct UserState: Codable, Hashable, Sendable {
    /// the watched jobs, oldest first (WATCH-01)
    public var watched: [WatchedJob]
    /// the build number hidden by hand, per job; it stays hidden until the job's last build has another number
    /// (HIDE-01)
    public var hidden: [String: Int]

    public init(watched: [WatchedJob] = [], hidden: [String: Int] = [:]) {
        self.watched = watched
        self.hidden = hidden
    }
}

/// A job whose builds are followed like mine, though it isn't mine (WATCH-04).
public struct WatchedJob: Codable, Hashable, Identifiable, Sendable {
    /// the job's name as in Jenkins URLs, like `MR-12` or `feature%252Ffoo`
    public var job: String
    /// the label it shows with, like `!12` or `feature/foo`
    public var label: String
    /// when it was watched
    public var added: Date

    public init(job: String, label: String, added: Date) {
        self.job = job
        self.label = label
        self.added = added
    }

    public var id: String { job }
}
