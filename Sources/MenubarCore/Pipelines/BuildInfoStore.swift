import Foundation
import Observation

/// What the build detail knows of a build's info (PIPE-11).
public enum BuildInfoState: Hashable, Sendable {
    /// not asked yet, or the request is under way
    case loading
    case loaded(BuildInfo)
    /// the last request failed
    case failed
}

/// What the build detail knows of its job's recent builds (PIPE-11).
public enum JobHistoryState: Hashable, Sendable {
    case loading
    /// the job's last builds, newest first
    case loaded([JobHistoryBuild])
    case failed
}

/// The info and the recent builds of the builds the user selected, loaded when the detail shows, never with the checks
/// (PIPE-11).
///
/// Both are kept in memory per build. A build that finished since they were loaded asks again, as its own entry in the
/// history changes with it; a failed request asks again at the next selection. The requests go through the Jenkins
/// recorder, so they show in Activity like the checks'.
@Observable @MainActor
public final class BuildInfoStore {
    private var infos: [BuildID: BuildInfoState] = [:]
    private var histories: [BuildID: JobHistoryState] = [:]
    /// the builds whose answers were loaded while they still ran
    @ObservationIgnored private var loadedRunning: Set<BuildID> = []
    @ObservationIgnored private var asking: Set<BuildID> = []
    @ObservationIgnored private let services: PipelinesServices

    /// - Parameter services: the transport, the Jenkins token and the team values; the logs record the requests
    public init(services: PipelinesServices) {
        self.services = services
    }

    /// Returns what is known of a build's info.
    ///
    /// - Parameter build: the build
    /// - Returns: ``BuildInfoState/loading`` for a build not asked yet
    public func info(of build: BuildID) -> BuildInfoState {
        infos[build] ?? .loading
    }

    /// Returns what is known of a build's job's recent builds.
    ///
    /// - Parameter build: the build
    /// - Returns: ``JobHistoryState/loading`` for a build not asked yet
    public func history(of build: BuildID) -> JobHistoryState {
        histories[build] ?? .loading
    }

    /// Loads a build's info and its job's recent builds when its detail shows: unless they are loaded or being loaded.
    ///
    /// Without a Jenkins token or the team values it asks nothing and fails quietly. Cancelling the calling task doesn't
    /// cancel the requests: the answers are small, and kept for when the build is selected again.
    ///
    /// - Parameter build: the selected build
    public func load(_ build: Build) async {
        let id = build.id
        if asking.contains(id) {
            return
        }
        let finishedSince = loadedRunning.contains(id) && !build.isRunning
        if !finishedSince, case .loaded? = infos[id], case .loaded? = histories[id] {
            return
        }
        // A finished build's info never changes: a kept one shows at once, and the job's history is asked once below,
        // as it gains builds (OD-07).
        var keptInfo: BuildInfo?
        if !build.isRunning, infos[id] == nil, let kept = services.details?.load(.buildInfo, key: id.detailKey) {
            keptInfo = kept.value
            infos[id] = .loaded(kept.value)
        }
        if histories[id] == nil, let kept = services.details?.load(.jobHistory, key: id.detailKey) {
            histories[id] = .loaded(kept.value)
        }
        asking.insert(id)
        // A refresh keeps showing the old answer until the new one is there.
        if !finishedSince {
            if !infos[id].isLoaded {
                infos[id] = .loading
            }
            if !histories[id].isLoaded {
                histories[id] = .loading
            }
        }
        let project = services.team.project(id.project) ?? services.team.primaryProject()
        let services = services
        let known = keptInfo
        let answers = await Task { () -> (BuildInfo?, [JobHistoryBuild]?)? in
            let token = await services.token(.jenkins)
            guard
                let client = try? JenkinsClient.make(
                    project: project, token: token, transport: services.recorder(for: project), timeouts: services.timeouts
                ).get()
            else {
                return nil
            }
            async let info = known == nil ? try? client.info(job: id.job, number: id.number, repository: project.team.gitLabProject) : known
            async let history = try? client.history(job: id.job)
            return (await info, await history)
        }.value
        asking.remove(id)
        if let info = answers?.0 {
            infos[id] = .loaded(info)
            if !build.isRunning, keptInfo == nil {
                services.details?.save(info, updatedAt: nil, as: .buildInfo, key: id.detailKey)
            }
        } else if !infos[id].isLoaded {
            infos[id] = .failed
        }
        if let history = answers?.1 {
            histories[id] = .loaded(history)
            services.details?.save(history, updatedAt: nil, as: .jobHistory, key: id.detailKey)
        } else if !histories[id].isLoaded {
            // A kept answer stays.
            histories[id] = .failed
        }
        if build.isRunning {
            loadedRunning.insert(id)
        } else {
            loadedRunning.remove(id)
        }
    }
}

extension DetailKind where Value == BuildInfo {
    /// a finished build's parameters, commit, cause and agent, which never change (OD-07)
    public static var buildInfo: DetailKind { DetailKind("build-info") }
}

extension DetailKind where Value == [JobHistoryBuild] {
    /// the recent builds of a build's job, shown at once and asked again (OD-07)
    public static var jobHistory: DetailKind { DetailKind("job-history") }
}

private extension Optional where Wrapped == BuildInfoState {
    var isLoaded: Bool {
        if case .loaded? = self { true } else { false }
    }
}

private extension Optional where Wrapped == JobHistoryState {
    var isLoaded: Bool {
        if case .loaded? = self { true } else { false }
    }
}
