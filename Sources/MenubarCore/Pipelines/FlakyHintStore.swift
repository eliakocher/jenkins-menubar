import Foundation
import Observation

/// What the build detail knows of whether a build's failed stages look flaky (PIPE-10).
public enum FlakyHintState: Hashable, Sendable {
    /// not asked yet, or the requests are under way
    case loading
    /// the hints; empty when the history says nothing useful
    case loaded([FlakyHint])
    /// a request failed: the hint is left out
    case failed
}

/// The "likely flaky" hints of the finished builds the user selected, loaded one build at a time when its detail shows,
/// never with the checks (PIPE-10).
///
/// Jenkins keeps each job's history, so nothing is stored: one request lists the job's recent builds with their commits,
/// and the stages are asked for the builds the rule needs (``FlakyRule/needingStages(for:in:)``): at most nine requests,
/// fewer for stages already known. A finished build doesn't change, so its stages and its hints stay in memory:
/// selecting it again asks nothing, and the next build of the job reuses the stages. After a failed request, the next
/// selection asks again. The requests go through the Jenkins recorder, so they show in Activity like the checks'.
@Observable @MainActor
public final class FlakyHintStore {
    private var states: [BuildID: FlakyHintState] = [:]
    @ObservationIgnored private var stagesByBuild: [BuildID: [Stage]] = [:]
    @ObservationIgnored private var asking: Set<BuildID> = []
    @ObservationIgnored private let services: PipelinesServices

    /// - Parameter services: the transport, the Jenkins token and the team values; the logs record the requests
    public init(services: PipelinesServices) {
        self.services = services
    }

    /// Returns what is known of a build's hints.
    ///
    /// - Parameter build: the build
    /// - Returns: ``FlakyHintState/loading`` for a build not asked yet
    public func state(of build: BuildID) -> FlakyHintState {
        states[build] ?? .loading
    }

    /// Loads the hints of a finished build when its detail shows: unless they are loaded or being loaded.
    ///
    /// Without a Jenkins token or the team values it asks nothing and fails quietly; so does a build with no failed stage,
    /// which has nothing to judge and asks nothing. Cancelling the calling task doesn't cancel the requests: the answers
    /// are small, and kept for when the build is selected again.
    ///
    /// - Parameters:
    ///   - build: the selected finished build
    ///   - stages: its stages, which the check already loaded
    public func load(_ build: BuildID, stages: [Stage]) async {
        if asking.contains(build) {
            return
        }
        if case .loaded? = states[build] {
            return
        }
        guard stages.contains(where: { $0.status == .failed || $0.status == .unstable }) else {
            states[build] = .loaded([])
            return
        }
        asking.insert(build)
        states[build] = .loading
        stagesByBuild[build] = stages
        let project = services.team.project(build.project) ?? services.team.primaryProject()
        let services = services
        let known = stagesByBuild.filter { $0.key.job == build.job && $0.key.project == build.project }
        let outcome = await Task { () -> (hints: [FlakyHint], stages: [Int: [Stage]])? in
            let token = await services.token(.jenkins)
            guard
                let client = try? JenkinsClient.make(
                    project: project, token: token, transport: services.recorder(for: project), timeouts: services.timeouts
                ).get(),
                let recent = try? await client.recentBuilds(job: build.job, repository: project.team.gitLabProject),
                let judged = recent.first(where: { $0.number == build.number })
            else {
                return nil
            }
            var runs: [Int: [Stage]] = [:]
            let wanted = FlakyRule.needingStages(for: judged, in: recent)
            for number in wanted {
                if let stages = known[BuildID(job: build.job, number: number, project: build.project)] {
                    runs[number] = stages
                }
            }
            let missing = wanted.filter { runs[$0] == nil }
            let loaded: [Int: [Stage]]? = await withTaskGroup(of: (Int, [Stage]?).self) { group in
                for number in missing {
                    group.addTask { (number, try? await client.stages(job: build.job, number: number)) }
                }
                var all: [Int: [Stage]] = [:]
                for await (number, stages) in group {
                    guard let stages else {
                        group.cancelAll()
                        return nil
                    }
                    all[number] = stages
                }
                return all
            }
            guard let loaded else {
                return nil
            }
            runs.merge(loaded) { $1 }
            let history = recent.map { BuildRun(build: $0, stages: runs[$0.number]) }
            return (FlakyRule.hints(for: judged, stages: stages, history: history), loaded)
        }.value
        asking.remove(build)
        if let outcome {
            for (number, stages) in outcome.stages {
                stagesByBuild[BuildID(job: build.job, number: number, project: build.project)] = stages
            }
            states[build] = .loaded(outcome.hints)
        } else {
            states[build] = .failed
        }
    }
}
