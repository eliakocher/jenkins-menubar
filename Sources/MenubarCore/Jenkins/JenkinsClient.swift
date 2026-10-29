import Foundation

/// Asks the team's Jenkins multibranch job for its jobs, their last builds, the stages, the test counts and the failed
/// tests, with Basic auth (NET-02) and the limits of `Timeouts` (NET-01). The requests and answers are the old plugin's,
/// except the failed tests, which are new.
///
/// Every failure is thrown as a `JenkinsError`, whose problem depends on the request:
/// - 401 or 403: the token is rejected (JERR-02);
/// - 404: for the job list or the account check, the job URL in Team is wrong (JERR-03); for anything under one job,
///   Jenkins dropped that job (JERR-04);
/// - no answer in time: for the job list, slow (JERR-06); for any other request, unreachable (JERR-05);
/// - no connection, an unknown host or any other transport failure: unreachable (JERR-05);
/// - another status: that HTTP status (JERR-08);
/// - a 2xx answer that isn't the JSON asked for, like a proxy's sign-in page: not JSON (JERR-08).
///
/// A cancelled request throws `CancellationError`.
public struct JenkinsClient: Sendable {
    /// the multibranch job, as in Team
    public let jobURL: URL
    // Internal for the rebuild's requests (`JenkinsClient+Rebuild.swift`); never logged, never in a URL.
    let token: String
    let transport: any HTTPTransport
    let timeouts: Timeouts

    /// Creates a client. Nothing is asked yet.
    ///
    /// - Parameters:
    ///   - jobURL: the multibranch job (`TeamValues.jenkinsJob`)
    ///   - token: the stored Jenkins token, base64 of `user:api-token`, sent as it is
    ///   - transport: the transport that sends the requests, usually a `RequestRecorder`
    ///   - timeouts: the time limits of the requests
    public init(jobURL: URL, token: String, transport: any HTTPTransport, timeouts: Timeouts = .standard) {
        self.jobURL = jobURL
        self.token = token
        self.transport = transport
        self.timeouts = timeouts
    }

    /// Returns the client of a project, or why there is none: missing team values (TEAM-03) come before a missing
    /// token (JERR-01), and neither makes a request.
    ///
    /// - Parameters:
    ///   - project: the project, whose Jenkins job URL the client asks
    ///   - token: the stored Jenkins token; `nil` or empty when there is none
    ///   - transport: the transport that sends the requests
    ///   - timeouts: the time limits of the requests
    /// - Returns: the client, or the problem that keeps Jenkins from being asked
    public static func make(
        project: Project,
        token: String?,
        transport: any HTTPTransport,
        timeouts: Timeouts = .standard
    ) -> Result<JenkinsClient, JenkinsError> {
        guard let jobURL = project.team.jenkinsJob else {
            return .failure(JenkinsError(.teamValuesMissing))
        }
        guard let token, !token.isEmpty else {
            return .failure(JenkinsError(.noToken(.jenkins)))
        }
        return .success(JenkinsClient(jobURL: jobURL, token: token, transport: transport, timeouts: timeouts))
    }

    /// Returns the jobs of the multibranch job, with the GitLab users who opened them (PIPE-01).
    ///
    /// Jenkins puts this list together slowly, so it gets the longer limit.
    ///
    /// - Returns: the jobs, in Jenkins' order
    public func jobs() async throws -> [JenkinsJob] {
        let answer: JobListAnswer = try await get(
            "/api/json?tree=jobs%5Bname,actions%5Bcontributor%5D%5D",
            timeout: timeouts.jenkinsJobList, notFound: .unknownJob, timedOut: .slow)
        return (answer.jobs ?? []).compactMap { job in
            guard let name = job.name, !name.isEmpty else { return nil }
            return JenkinsJob(job: Self.pathSegment(forName: name), contributors: (job.actions ?? []).compactMap { $0?.contributor })
        }
    }

    /// Returns a job's title, links and author, and its last build (PIPE-02, PIPE-03, WATCH-01).
    ///
    /// - Parameter job: the job's name as in Jenkins URLs, like `MR-12` or `feature%252Ffoo`
    /// - Returns: the job and its last build
    public func job(_ job: String) async throws -> JenkinsJobStatus {
        let answer: JobAnswer = try await get(
            "/job/\(Self.safe(job))/api/json?tree=actions%5BobjectDisplayName,objectUrl,contributorDisplayName%5D,"
                + "lastBuild%5Bnumber,building,result,timestamp,estimatedDuration,duration%5D",
            timeout: timeouts.jenkins, notFound: .gone, timedOut: .unreachable(.jenkins))
        let actions = (answer.actions ?? []).compactMap { $0 }
        func first(_ field: (Action) -> String?) -> String? {
            actions.lazy.compactMap(field).first { !$0.isEmpty }
        }
        return JenkinsJobStatus(
            job: job,
            title: first(\.objectDisplayName),
            gitLabURL: first(\.objectUrl).flatMap { URL(string: $0) },
            author: first(\.contributorDisplayName),
            lastBuild: answer.lastBuild.flatMap(Self.lastBuild))
    }

    /// Returns the stages of a build, from `wfapi/describe` (PIPE-02, PIPE-04).
    ///
    /// - Parameters:
    ///   - job: the job's name as in Jenkins URLs
    ///   - number: the build number
    /// - Returns: the stages, in order
    public func stages(job: String, number: Int) async throws -> [Stage] {
        let answer: DescribeAnswer = try await get(
            "/job/\(Self.safe(job))/\(number)/wfapi/describe",
            timeout: timeouts.jenkins, notFound: .gone, timedOut: .unreachable(.jenkins))
        return (answer.stages ?? []).map {
            Stage(name: $0.name ?? "", status: Stage.Status(rawValue: $0.status ?? ""), duration: ($0.durationMillis ?? 0) / 1000)
        }
    }

    /// Returns the failed and total tests of a build, summed over its test reports (PIPE-03, ALERT-02).
    ///
    /// - Parameters:
    ///   - job: the job's name as in Jenkins URLs
    ///   - number: the build number
    /// - Returns: the counts; `nil` when the build has no test report
    public func testCounts(job: String, number: Int) async throws -> TestCounts? {
        let answer: TestCountsAnswer = try await get(
            "/job/\(Self.safe(job))/\(number)/api/json?tree=actions%5BfailCount,totalCount%5D",
            timeout: timeouts.jenkins, notFound: .gone, timedOut: .unreachable(.jenkins))
        let reports = (answer.actions ?? []).compactMap { $0 }.filter { $0.totalCount != nil }
        guard !reports.isEmpty else { return nil }
        return TestCounts(failed: reports.reduce(0) { $0 + ($1.failCount ?? 0) }, total: reports.reduce(0) { $0 + ($1.totalCount ?? 0) })
    }

    /// Returns the failed tests of a build, from its test report (PIPE-03).
    ///
    /// The request keeps only the class, name, status and error message of each case. A test counts as failed when
    /// its status is FAILED or REGRESSION. The tests keep the order of the report.
    ///
    /// - Parameters:
    ///   - job: the job's name as in Jenkins URLs
    ///   - number: the build number
    /// - Returns: the failed tests; empty when the report lists none, or the build has no test report (a 404)
    public func failedTests(job: String, number: Int) async throws -> [FailedTest] {
        let answer: TestReportAnswer
        do {
            answer = try await get(
                "/job/\(Self.safe(job))/\(number)/testReport/api/json"
                    + "?tree=suites%5Bcases%5BclassName,name,status,errorDetails%5D%5D",
                timeout: timeouts.jenkins, notFound: .gone, timedOut: .unreachable(.jenkins))
        } catch let error as JenkinsError where error.problem == .gone {
            // A build with test counts from another kind of report has no `testReport` page.
            return []
        }
        return (answer.suites ?? []).flatMap { $0?.cases ?? [] }.compactMap { testCase in
            guard let testCase, let status = FailedTest.Status(rawValue: testCase.status ?? "") else {
                return nil
            }
            return FailedTest(
                className: testCase.className ?? "", name: testCase.name ?? "", status: status,
                message: FailedTest.preview(of: testCase.errorDetails))
        }
    }

    /// Asks Jenkins for the multibranch job with the token, which tells whether Jenkins takes it (ACC-04).
    ///
    /// - Returns: the Jenkins user of the token, the part before its `:`; `nil` when the token isn't base64 of
    ///   `user:api-token`
    public func account() async throws -> String? {
        let _: AnyAnswer = try await get(
            "/api/json?tree=name", timeout: timeouts.jenkins, notFound: .unknownJob, timedOut: .unreachable(.jenkins))
        return TokenStore.jenkinsUser(fromToken: token)
    }

    /// Returns a job's name from the job list in the form Jenkins URLs use.
    ///
    /// The list names a branch's job with the branch encoded once, like `release%2F8.x`; its URL encodes that name
    /// again, `release%252F8.x`. `MR-12` stays as it is.
    ///
    /// - Parameter name: the job's `name` in the list
    /// - Returns: the name as in Jenkins URLs
    public static func pathSegment(forName name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: segmentCharacters) ?? name
    }

    private static let segmentCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    /// The job as given, with only what can't stand in a URL path segment encoded: its `%` escapes stay.
    static func safe(_ job: String) -> String {
        job.addingPercentEncoding(withAllowedCharacters: segmentCharacters.union(CharacterSet(charactersIn: "%"))) ?? job
    }

    func get<Answer: Decodable>(
        _ pathAndQuery: String,
        timeout: Duration,
        notFound: Problem,
        timedOut: Problem
    ) async throws -> Answer {
        var root = jobURL.absoluteString
        while root.hasSuffix("/") {
            root.removeLast()
        }
        guard let url = URL(string: root + pathAndQuery) else {
            throw JenkinsError(notFound)
        }
        let request = HTTPRequest(url: url, headers: ["Authorization": "Basic \(token)"], timeout: timeout)
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch TransportError.noAnswer {
            throw JenkinsError(timedOut)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // curl's other failures made the old plugin give up on Jenkins for the check too.
            throw JenkinsError(.unreachable(.jenkins))
        }
        switch response.status {
        case 200..<300:
            do {
                return try JSONDecoder().decode(Answer.self, from: response.body)
            } catch {
                // Most likely a proxy's sign-in page, which Jenkins' JSON API never sends.
                throw JenkinsError(.notJSON)
            }
        case 401, 403:
            throw JenkinsError(.rejectedToken(.jenkins))
        case 404:
            throw JenkinsError(notFound)
        default:
            throw JenkinsError(.httpStatus(.jenkins, status: response.status))
        }
    }

    private static func lastBuild(_ answer: LastBuildAnswer) -> JenkinsJobStatus.LastBuild? {
        guard let number = answer.number, number > 0 else { return nil }
        // A build that stopped building gets its result a moment later; until then it counts as running, so its
        // alert comes with the result.
        let phase: BuildPhase =
            if answer.building != true, let result = answer.result {
                .finished(result: BuildResult(rawValue: result), duration: (answer.duration ?? 0) / 1000)
            } else {
                .running
            }
        return JenkinsJobStatus.LastBuild(
            number: number,
            phase: phase,
            startedAt: Date(timeIntervalSince1970: (answer.timestamp ?? 0) / 1000),
            estimatedDuration: answer.estimatedDuration.flatMap { $0 > 0 ? $0 / 1000 : nil })
    }
}

/// Why a Jenkins request gave no usable answer, as the problem it makes. `JenkinsClient` documents which problem each
/// failure makes.
public struct JenkinsError: Error, Hashable, Sendable, CustomStringConvertible {
    public var problem: Problem

    public init(_ problem: Problem) {
        self.problem = problem
    }

    public var description: String { problem.message }
}

extension JenkinsError: LocalizedError {
    public var errorDescription: String? { problem.message }
}

/// A job of the multibranch job's list, with the GitLab users who opened it (PIPE-01).
public struct JenkinsJob: Hashable, Sendable {
    /// the job's name as in Jenkins URLs, like `MR-12` or `release%252F8.x`
    public var job: String
    /// the GitLab usernames of Jenkins' `contributor` actions; empty for a branch's job
    public var contributors: [String]

    public init(job: String, contributors: [String]) {
        self.job = job
        self.contributors = contributors
    }
}

/// A job's title, links and author, and its last build, from `/job/<job>/api/json`.
public struct JenkinsJobStatus: Hashable, Sendable {
    /// the job's name as in Jenkins URLs
    public var job: String
    /// Jenkins' `objectDisplayName`, the MR or branch title; `nil` when empty or missing
    public var title: String?
    /// Jenkins' `objectUrl`: the merge request, or the branch in GitLab
    public var gitLabURL: URL?
    /// Jenkins' `contributorDisplayName`
    public var author: String?
    /// the last build; `nil` when the job has none yet (PIPE-01)
    public var lastBuild: LastBuild?

    public init(job: String, title: String? = nil, gitLabURL: URL? = nil, author: String? = nil, lastBuild: LastBuild? = nil) {
        self.job = job
        self.title = title
        self.gitLabURL = gitLabURL
        self.author = author
        self.lastBuild = lastBuild
    }

    /// The last build of a job, as Jenkins tells it.
    public struct LastBuild: Hashable, Sendable {
        /// the build number, 1 or more
        public var number: Int
        /// running, or finished with its result; running until Jenkins has the result
        public var phase: BuildPhase
        public var startedAt: Date
        /// `nil` when Jenkins has no estimate
        public var estimatedDuration: TimeInterval?

        public init(number: Int, phase: BuildPhase, startedAt: Date, estimatedDuration: TimeInterval? = nil) {
            self.number = number
            self.phase = phase
            self.startedAt = startedAt
            self.estimatedDuration = estimatedDuration
        }
    }

    /// Returns the job's last build, without stages or test counts.
    ///
    /// - Parameter kind: whether the job is mine or watched
    /// - Returns: the build; `nil` when the job has no build yet
    public func build(kind: JobKind) -> Build? {
        lastBuild.map {
            Build(
                job: job, number: $0.number, title: title, gitLabURL: gitLabURL, author: author, kind: kind,
                phase: $0.phase, startedAt: $0.startedAt, estimatedDuration: $0.estimatedDuration)
        }
    }
}

// The answers, read leniently: Jenkins leaves out what a job doesn't have, and an action can be `{}` or `null`.

private struct Action: Decodable {
    var objectDisplayName: String?
    var objectUrl: String?
    var contributorDisplayName: String?
    var contributor: String?
    var failCount: Int?
    var totalCount: Int?
}

private struct JobListAnswer: Decodable {
    struct Job: Decodable {
        var name: String?
        var actions: [Action?]?
    }

    var jobs: [Job]?
}

private struct LastBuildAnswer: Decodable {
    var number: Int?
    var building: Bool?
    var result: String?
    /// milliseconds since 1970
    var timestamp: Double?
    /// milliseconds; -1 without an estimate
    var estimatedDuration: Double?
    /// milliseconds; 0 while running
    var duration: Double?
}

private struct JobAnswer: Decodable {
    var actions: [Action?]?
    var lastBuild: LastBuildAnswer?
}

private struct DescribeAnswer: Decodable {
    struct Stage: Decodable {
        var name: String?
        var status: String?
        var durationMillis: Double?
    }

    var stages: [Stage]?
}

private struct TestCountsAnswer: Decodable {
    var actions: [Action?]?
}

private struct TestReportAnswer: Decodable {
    struct Suite: Decodable {
        var cases: [Case?]?
    }

    struct Case: Decodable {
        var className: String?
        var name: String?
        var status: String?
        var errorDetails: String?
    }

    var suites: [Suite?]?
}

/// Any JSON object.
private struct AnyAnswer: Decodable {}
