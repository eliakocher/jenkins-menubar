import Foundation
import Observation

/// What the build detail knows of a build's failed tests (PIPE-03).
public enum FailedTestsState: Hashable, Sendable {
    /// not asked yet, or the request is under way
    case loading
    /// the failed tests of the report; empty when it lists none
    case loaded([FailedTest])
    /// the last request failed
    case failed
}

/// The failed tests of the finished builds the user selected, loaded one build at a time when its detail shows, never
/// with the checks (PIPE-03).
///
/// A build's tests are kept in memory: a finished build doesn't change, so selecting it again asks nothing. After a
/// failed request, the next selection or Try Again asks again. The request goes through the Jenkins recorder, so it
/// shows in Activity like the checks' requests.
@Observable @MainActor
public final class FailedTestsStore {
    private var states: [BuildID: FailedTestsState] = [:]
    /// the builds whose request is under way, so that a second selection doesn't send another
    @ObservationIgnored private var asking: Set<BuildID> = []
    @ObservationIgnored private let services: PipelinesServices

    /// - Parameter services: the transport, the Jenkins token and the team values; the logs record the requests
    public init(services: PipelinesServices) {
        self.services = services
    }

    /// Returns what is known of a build's failed tests.
    ///
    /// - Parameter build: the build
    /// - Returns: ``FailedTestsState/loading`` for a build not asked yet
    public func state(of build: BuildID) -> FailedTestsState {
        states[build] ?? .loading
    }

    /// Loads a build's failed tests when its detail shows: unless they are loaded or being loaded.
    ///
    /// Without a Jenkins token or the team values it asks nothing and fails quietly. Cancelling the calling task
    /// doesn't cancel the request: the answer is small, and kept for when the build is selected again.
    ///
    /// - Parameter build: the selected finished build
    public func load(_ build: BuildID) async {
        if asking.contains(build) {
            return
        }
        if case .loaded? = states[build] {
            return
        }
        asking.insert(build)
        states[build] = .loading
        let project = services.team.project(build.project) ?? services.team.primaryProject()
        let services = services
        let tests = await Task { () -> [FailedTest]? in
            let token = await services.token(.jenkins)
            guard
                let client = try? JenkinsClient.make(
                    project: project, token: token, transport: services.recorder(for: project), timeouts: services.timeouts
                ).get()
            else {
                return nil
            }
            return try? await client.failedTests(job: build.job, number: build.number)
        }.value
        asking.remove(build)
        states[build] = tests.map(FailedTestsState.loaded) ?? .failed
    }
}
