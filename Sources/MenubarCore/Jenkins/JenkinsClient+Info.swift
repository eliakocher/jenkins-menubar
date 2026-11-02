import Foundation

/// What the build detail's Build Info card shows of one build beyond the list's data (PIPE-11).
public struct BuildInfo: Codable, Hashable, Sendable {
    /// the build's parameters, in Jenkins's order; without the ones that hold a secret
    public var parameters: [BuildParameter]
    /// the commit the build started from, lowercase; `nil` when Jenkins named none
    public var commit: String?
    /// what started the build, as Jenkins words it: "Started by user Jane Doe", "Started by GitLab push by Jane Doe"
    public var cause: String?
    /// the agent the build ran on, like `linux-agent-3`; `nil` for the built-in node, a pipeline's many nodes, or when
    /// Jenkins names none
    public var node: String?
    /// what Jenkins expects the build to take, its average of the job's recent successful builds; `nil` without one
    public var estimatedDuration: TimeInterval?

    public init(
        parameters: [BuildParameter] = [], commit: String? = nil, cause: String? = nil, node: String? = nil,
        estimatedDuration: TimeInterval? = nil
    ) {
        self.parameters = parameters
        self.commit = commit.map { $0.lowercased() }
        self.cause = cause
        self.node = node
        self.estimatedDuration = estimatedDuration
    }

    /// whether the card has nothing to show
    public var isEmpty: Bool {
        parameters.isEmpty && commit == nil && cause == nil && node == nil && estimatedDuration == nil
    }

    /// Returns whether a parameter's name says its value is a secret, which the card never shows.
    ///
    /// - Parameter name: the parameter's name
    /// - Returns: `true` for names like `DEPLOY_PASSWORD`, `API_TOKEN` or `client-secret`
    public static func isSecret(_ name: String) -> Bool {
        let name = name.lowercased()
        return ["password", "passwd", "secret", "token", "apikey", "api_key", "api-key", "credential"].contains {
            name.contains($0)
        }
    }
}

/// A build of a job's recent history, for the build detail's strip (PIPE-11).
public struct JobHistoryBuild: Codable, Hashable, Sendable, Identifiable {
    public var number: Int
    /// the result; `nil` while the build runs
    public var result: BuildResult?
    /// how long a finished build took; `nil` while it runs
    public var duration: TimeInterval?
    public var startedAt: Date?

    public init(number: Int, result: BuildResult?, duration: TimeInterval? = nil, startedAt: Date? = nil) {
        self.number = number
        self.result = result
        self.duration = duration
        self.startedAt = startedAt
    }

    public var id: Int { number }
    public var isRunning: Bool { result == nil }
}

extension JenkinsClient {
    /// Returns one build's info: its parameters, commit, cause, node and the job's expected duration (PIPE-11).
    ///
    /// Two requests at once: the standard `ParametersAction` (as ``parameters(job:number:)``), and one `tree` for
    /// `builtOn`, `estimatedDuration`, the `CauseAction`'s causes and the git `BuildData` (the commit as for
    /// ``recentBuilds(job:repository:limit:)``). A pipeline run has no `builtOn`; its stages' `execNode` stands in, from
    /// `wfapi/describe`, when they name one. A failure of the second request fails the call; the parameters' failure
    /// only leaves them out.
    ///
    /// - Parameters:
    ///   - job: the job's name as in Jenkins URLs
    ///   - number: the build number
    ///   - repository: the GitLab project's path, to tell the job's repository from a library's; empty when unknown
    /// - Returns: the info
    public func info(job: String, number: Int, repository: String = "") async throws -> BuildInfo {
        async let parameters = try? self.parameters(job: job, number: number)
        let git = "lastBuiltRevision[SHA1],remoteUrls,buildsByBranchName[buildNumber,marked[SHA1],*[buildNumber,marked[SHA1]]]"
        let tree = "number,builtOn,estimatedDuration,actions[causes[shortDescription],\(git)]"
        let answer: InfoAnswer = try await get(
            "/job/\(Self.safe(job))/\(number)/api/json?tree=" + Self.encodeTree(tree),
            timeout: timeouts.jenkins, notFound: .gone, timedOut: .unreachable(.jenkins))
        var node = answer.builtOn.flatMap { $0.isEmpty ? nil : $0 }
        if node == nil {
            node = await executionNode(job: job, number: number)
        }
        let cause = answer.causes.lazy.compactMap { $0.shortDescription?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        let commit = HistoryAnswer.Build(number: answer.number ?? number, result: nil, building: nil, actions: answer.git)
            .commit(inRepository: repository)
        return BuildInfo(
            parameters: (await parameters ?? []).filter { !BuildInfo.isSecret($0.name) }, commit: commit, cause: cause,
            node: node, estimatedDuration: answer.estimatedDuration.flatMap { $0 > 0 ? $0 / 1000 : nil })
    }

    /// Returns a job's last builds, running ones included, newest first (PIPE-11).
    ///
    /// - Parameters:
    ///   - job: the job's name as in Jenkins URLs
    ///   - limit: how many builds Jenkins lists
    /// - Returns: the builds
    public func history(job: String, limit: Int = 10) async throws -> [JobHistoryBuild] {
        let tree = "builds[number,result,building,duration,timestamp]{0,\(limit)}"
        let answer: SummaryAnswer = try await get(
            "/job/\(Self.safe(job))/api/json?tree=" + Self.encodeTree(tree),
            timeout: timeouts.jenkins, notFound: .gone, timedOut: .unreachable(.jenkins))
        return (answer.builds ?? []).compactMap { build in
            guard let number = build.number, number > 0 else { return nil }
            let running = build.building == true || build.result == nil
            return JobHistoryBuild(
                number: number, result: running ? nil : build.result.map { BuildResult(rawValue: $0) },
                duration: running ? nil : build.duration.map { $0 / 1000 },
                startedAt: build.timestamp.map { Date(timeIntervalSince1970: $0 / 1000) })
        }
    }

    /// The one agent every stage of a pipeline ran on, from the stages' `execNode`; `nil` for none or several.
    private func executionNode(job: String, number: Int) async -> String? {
        let answer: NodesAnswer? = try? await get(
            "/job/\(Self.safe(job))/\(number)/wfapi/describe",
            timeout: timeouts.jenkins, notFound: .gone, timedOut: .unreachable(.jenkins))
        let names = Set((answer?.stages ?? []).compactMap { $0.execNode }.filter { !$0.isEmpty })
        return names.count == 1 ? names.first : nil
    }
}

private struct InfoAnswer: Decodable {
    struct Cause: Decodable {
        var shortDescription: String?
    }

    struct CauseAction: Decodable {
        var causes: [Cause?]?
    }

    var number: Int?
    var builtOn: String?
    var estimatedDuration: Double?
    /// the causes of every `CauseAction`
    var causes: [Cause] = []
    /// the git `BuildData` actions, read as the history reads them
    var git: [Lenient<HistoryAnswer.BuildData>?]?

    private enum CodingKeys: String, CodingKey {
        case number, builtOn, estimatedDuration, actions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try? container.decode(Int.self, forKey: .number)
        builtOn = try? container.decode(String.self, forKey: .builtOn)
        estimatedDuration = try? container.decode(Double.self, forKey: .estimatedDuration)
        git = try? container.decode([Lenient<HistoryAnswer.BuildData>?].self, forKey: .actions)
        let actions = (try? container.decode([Lenient<CauseAction>?].self, forKey: .actions)) ?? []
        causes = actions.compactMap { $0?.value?.causes }.joined().compactMap { $0 }
    }
}

private struct SummaryAnswer: Decodable {
    struct Build: Decodable {
        var number: Int?
        var result: String?
        var building: Bool?
        var duration: Double?
        var timestamp: Double?
    }

    var builds: [Build]?
}

private struct NodesAnswer: Decodable {
    struct Stage: Decodable {
        var execNode: String?
    }

    var stages: [Stage]?
}
