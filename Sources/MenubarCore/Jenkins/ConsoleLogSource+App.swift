import Foundation

extension AppModel {
    /// Returns where a build's console log is read: Jenkins, through the recorder, so each read shows in Activity by
    /// its path, never with its text (PIPE-12). Nothing is read before the loader asks.
    ///
    /// - Parameter build: the build
    /// - Returns: the source, which reads the token and the team values at each read
    public func consoleLogSource(for build: BuildID) -> ConsoleLogSource {
        let team = team
        let tokens = tokens
        let transport = dependencies.transport
        let clock = dependencies.clock
        let timeouts = dependencies.timeouts
        let log = log
        let capture = requestCapture
        return ConsoleLogSource { start, limit in
            let project = team.project(build.project) ?? team.primaryProject()
            let token = try? await tokens.token(.jenkins)
            let recorder = RequestRecorder(
                wrapping: transport, log: log, capture: capture, clock: clock, pathsRelativeTo: project.team.jenkinsJob)
            let client = try JenkinsClient.make(project: project, token: token, transport: recorder, timeouts: timeouts).get()
            return try await client.consoleLog(job: build.job, number: build.number, from: start, limit: limit)
        }
    }
}
