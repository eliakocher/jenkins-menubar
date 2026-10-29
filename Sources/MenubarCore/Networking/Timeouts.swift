import Foundation

/// The time limits of NET-01. The clients pick a request's limit from here; the transport's connection probe uses
/// `connect`.
public struct Timeouts: Sendable, Hashable {
    /// how long a host may take to accept a TCP connection
    public var connect: Duration
    /// the Jenkins job list with its contributors (PIPE-01), which Jenkins is slow to put together
    public var jenkinsJobList: Duration
    /// every other Jenkins request: a job, a build, its stages and test counts, the account check
    public var jenkins: Duration
    /// every GitLab GraphQL operation
    public var gitLab: Duration

    public init(connect: Duration, jenkinsJobList: Duration, jenkins: Duration, gitLab: Duration) {
        self.connect = connect
        self.jenkinsJobList = jenkinsJobList
        self.jenkins = jenkins
        self.gitLab = gitLab
    }

    /// The limits the app uses.
    public static let standard = Timeouts(
        connect: .seconds(5),
        jenkinsJobList: .seconds(60),
        jenkins: .seconds(20),
        gitLab: .seconds(30)
    )
}
