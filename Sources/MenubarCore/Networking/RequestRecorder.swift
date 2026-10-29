import Foundation

/// Logs and keeps every request that goes through it, then answers with what the wrapped transport answered
/// (LOG-01, LOG-02, LOG-05).
///
/// - The log entry names a Jenkins request by its method and path, without the query, and a GitLab request by its
///   GraphQL operation: "GET /job/MR-1/api/json in 0.01s", "POST WorkItems: HTTP 500 in 0.20s".
/// - The kept request has no token and no cookie: `RequestRecord` keeps only the scheme of `Authorization`, and the
///   response headers without `Set-Cookie`.
/// - The request counts for the check that `CheckTimes.measure` runs around it.
///
/// A request whose task was cancelled is neither logged nor kept: nobody waits for its answer.
public struct RequestRecorder: HTTPTransport {
    private let transport: any HTTPTransport
    private let log: ActivityLog
    private let capture: RequestCapture?
    private let clock: any Clock<Duration>
    /// the path Jenkins paths are logged relative to, without a trailing `/`
    private let rootPath: String?

    /// - Parameters:
    ///   - transport: the transport that sends the requests
    ///   - log: where each request gets its entry
    ///   - capture: where each request is kept with its response; nil keeps none
    ///   - clock: the clock that times the requests
    ///   - root: the Jenkins job URL; the paths of the requests under it are logged relative to it, like the old tool's
    ///     "GET /job/MR-1/api/json". A cheap value: make a new recorder when the job URL changes.
    public init(
        wrapping transport: any HTTPTransport,
        log: ActivityLog,
        capture: RequestCapture?,
        clock: any Clock<Duration> = ContinuousClock(),
        pathsRelativeTo root: URL? = nil
    ) {
        self.transport = transport
        self.log = log
        self.capture = capture
        self.clock = clock
        self.rootPath = root.map { String($0.path(percentEncoded: true).trimmingSuffix("/")) }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var result: Result<HTTPResponse, any Error> = .failure(CancellationError())
        let duration = await clock.measure {
            do {
                result = .success(try await transport.send(request))
            } catch {
                result = .failure(error)
            }
        }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let took = String(format: "%.2fs", seconds)
        let name = name(of: request)
        let source: ActivityEntry.Source = request.graphQL == nil ? .jenkins : .gitlab

        let record: RequestRecord
        let level: ActivityEntry.Level
        let message: String
        let outcome: ActivityEntry.Outcome
        switch result {
        case .success(let response):
            record = RequestRecord(request: request, response: response, seconds: seconds)
            if (200..<300).contains(response.status) {
                (level, message, outcome) = (.debug, "\(name) in \(took)", .ok(String(response.status)))
            } else {
                (level, message, outcome) = (.warning, "\(name): HTTP \(response.status) in \(took)", .failed(String(response.status)))
            }
        case .failure(let error) where error is CancellationError:
            throw error
        case .failure(let error as TransportError):
            record = RequestRecord(request: request, response: nil, error: error.message, seconds: seconds)
            (level, message, outcome) = (.warning, "\(name): \(error.message)", .failed(error.outcomeLabel))
        case .failure(let error):
            record = RequestRecord(request: request, response: nil, error: error.localizedDescription, seconds: seconds)
            (level, message, outcome) = (.warning, "\(name): \(error.localizedDescription)", .failed("ERROR"))
        }

        let requestID = await capture?.save(record)
        await log.log(level, source, message, outcome: outcome, requestID: requestID)
        await CheckTally.current.get()?.add(seconds: seconds, failed: outcome.kind != .ok)
        return try result.get()
    }

    /// "GET /job/MR-1/api/json", or "POST WorkItems".
    private func name(of request: HTTPRequest) -> String {
        if let graphQL = request.graphQL {
            return "\(request.method) \(graphQL.name)"
        }
        var path = request.url.path(percentEncoded: true)
        if let rootPath, !rootPath.isEmpty, path == rootPath || path.hasPrefix(rootPath + "/") {
            path = String(path.dropFirst(rootPath.count))
        }
        return "\(request.method) \(path.isEmpty ? "/" : path)"
    }
}

private extension String {
    func trimmingSuffix(_ suffix: Character) -> Substring {
        var trimmed = self[...]
        while trimmed.last == suffix {
            trimmed.removeLast()
        }
        return trimmed
    }
}
