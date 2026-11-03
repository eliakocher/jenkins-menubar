import Foundation

/// Sends requests through an ephemeral URLSession that keeps no cookies, no cache and no credentials (NET-02).
///
/// URLSession has no connect timeout, so `ConnectProbe` checks first that the host takes a connection within the
/// connect limit. It runs before the first request to a host, and again once the host has given no answer for
/// `probeReuse`: once per host per check. Then the request has its own time limit, which is enforced by cancelling the
/// task; when the limit runs out, the task's metrics tell "no connection" from "no answer" (NET-01).
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let probe: ConnectProbe
    private let connectTimeout: Duration
    private let probeReuse: Duration
    private let clock: any Clock<Duration>
    private let reachedHosts = ReachedHosts()

    /// Creates a transport with its own session.
    ///
    /// - Parameters:
    ///   - connectTimeout: how long a host may take to accept a connection
    ///   - probeReuse: how long after an answer from a host its requests skip the probe
    ///   - clock: the clock of the time limits
    public init(
        connectTimeout: Duration = Timeouts.standard.connect,
        probeReuse: Duration = .seconds(10),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
        probe = ConnectProbe(clock: clock)
        self.connectTimeout = connectTimeout
        self.probeReuse = probeReuse
        self.clock = clock
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let host = request.url.host(percentEncoded: false) else {
            throw TransportError.other("no host in \(request.url.absoluteString)")
        }
        let port = request.url.port ?? (request.url.scheme?.lowercased() == "https" ? 443 : 80)
        let key = "\(host):\(port)"
        do {
            if await !reachedHosts.answered(key, within: probeReuse, now: clock.now) {
                try await checkConnection(host: host, port: port, limit: min(connectTimeout, request.timeout))
            }
            let response = try await exchange(request)
            await reachedHosts.record(key, now: clock.now)
            return response
        } catch {
            await reachedHosts.forget(key)
            throw error
        }
    }

    private func checkConnection(host: String, port: Int, limit: Duration) async throws {
        let result = await probe.check(host: host, port: port, timeout: limit)
        try Task.checkCancellation()
        switch result {
        case .connected: return
        case .timedOut: throw TransportError.noConnection(within: limit)
        case .unknownHost: throw TransportError.unknownHost
        case .cannotConnect: throw TransportError.cannotConnect
        case .failed(let description): throw TransportError.other(description)
        }
    }

    /// Runs the task against the request's time limit, and cancels whichever of the two comes second.
    private func exchange(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = Self.urlRequest(for: request)
        let metrics = MetricsCollector(followsRedirects: request.followsRedirects)
        let session = session
        let clock = clock
        let outcome: Result<(Data, URLResponse), any Error>? = await withTaskGroup(of: Result<(Data, URLResponse), any Error>?.self) { group in
            group.addTask {
                do {
                    if let limit = request.bodyLimit {
                        return .success(try await Self.data(for: urlRequest, upTo: limit, session: session, delegate: metrics))
                    }
                    return .success(try await session.data(for: urlRequest, delegate: metrics))
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                do {
                    try await clock.sleep(for: request.timeout)
                } catch {
                    return nil
                }
                return .failure(DeadlinePassed())
            }
            defer {
                group.cancelAll()
            }
            for await outcome in group {
                if let outcome {
                    return outcome
                }
            }
            return nil
        }
        // The group waited for the cancelled task to end, and URLSession hands over the metrics before that.
        try Task.checkCancellation()
        switch outcome {
        case .success(let (data, response)):
            guard let response = response as? HTTPURLResponse else {
                throw TransportError.other("not an HTTP answer from \(request.url.absoluteString)")
            }
            var headers: [String: String] = [:]
            for case let (name as String, value as String) in response.allHeaderFields {
                headers[name] = value
            }
            return HTTPResponse(status: response.statusCode, headers: headers, body: data)
        case .failure(let error):
            throw TransportError(error, connected: metrics.connected, limit: request.timeout)
        case nil:
            throw CancellationError()
        }
    }

    /// Reads at most `limit` bytes of the body, then cancels the task, so the rest never comes over the wire.
    private static func data(
        for request: URLRequest, upTo limit: Int, session: URLSession, delegate: MetricsCollector
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        var body: [UInt8] = []
        body.reserveCapacity(min(limit, 4 << 20))
        if limit > 0 {
            for try await byte in bytes {
                body.append(byte)
                if body.count >= limit {
                    break
                }
            }
        }
        bytes.task.cancel()
        return (Data(body), response)
    }

    private static func urlRequest(for request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        // URLSession's own timeout fires only after this long without any data; the limit is the deadline in exchange.
        urlRequest.timeoutInterval = Double(request.timeout.components.seconds) + 60
        return urlRequest
    }
}

extension TransportError {
    /// Classifies a failed task: a timeout by the task's metrics, anything else by its URLError code.
    ///
    /// - Parameters:
    ///   - error: what the task threw, or `DeadlinePassed` when the time limit ran out first
    ///   - connected: whether the metrics show a connection; nil without metrics
    ///   - limit: the request's time limit
    init(_ error: any Error, connected: Bool?, limit: Duration) {
        if error is DeadlinePassed || (error as? URLError)?.code == .timedOut {
            // Without metrics the probe's connection is the best guess.
            self = connected == false ? .noConnection(within: limit) : .noAnswer(within: limit)
            return
        }
        switch (error as? URLError)?.code {
        case .cannotFindHost?, .dnsLookupFailed?:
            self = .unknownHost
        case .cannotConnectToHost?, .notConnectedToInternet?, .internationalRoamingOff?, .dataNotAllowed?, .callIsActive?:
            self = .cannotConnect
        default:
            self = .other(error.localizedDescription)
        }
    }
}

/// Thrown inside the transport when a request's time limit runs out before its answer.
struct DeadlinePassed: Error {}

/// Collects the task's metrics, which URLSession delivers before the task ends, also when it is cancelled, and keeps
/// the task from following a redirect when the request says so.
private final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: URLSessionTaskMetrics?
    private let followsRedirects: Bool

    init(followsRedirects: Bool) {
        self.followsRedirects = followsRedirects
    }

    /// whether a transaction got a connection; nil when no metrics came
    var connected: Bool? {
        lock.withLock {
            metrics.map { metrics in
                metrics.transactionMetrics.contains { transaction in
                    // A reused connection has no connect dates.
                    transaction.connectEndDate != nil || transaction.isReusedConnection || transaction.requestStartDate != nil
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock {
            self.metrics = metrics
        }
    }

    /// Without following, the task ends with the 3xx answer itself. A redirect to another origin is never followed: the
    /// request carries the token (security audit, finding 7).
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard followsRedirects, let from = task.currentRequest?.url ?? task.originalRequest?.url, let to = request.url,
            RedirectPolicy.allows(from: from, to: to)
        else {
            return nil
        }
        return request
    }
}

/// Which redirects a request may follow: only within its own origin, since it carries the token in its
/// `Authorization` header (security audit, finding 7). A refused redirect ends the request with the 3xx answer.
public enum RedirectPolicy {
    /// Returns whether a redirect keeps the scheme, the host and the port, ignoring case and the default ports; https
    /// to http is refused as a change of scheme.
    ///
    /// - Parameters:
    ///   - from: the URL that answered with the redirect
    ///   - to: the URL it points to
    /// - Returns: `true` for the same origin
    public static func allows(from: URL, to: URL) -> Bool {
        guard let fromScheme = from.scheme?.lowercased(), let toScheme = to.scheme?.lowercased(), fromScheme == toScheme,
            let fromHost = from.host(percentEncoded: false)?.lowercased(),
            let toHost = to.host(percentEncoded: false)?.lowercased(), fromHost == toHost
        else {
            return false
        }
        return port(of: from, scheme: fromScheme) == port(of: to, scheme: toScheme)
    }

    private static func port(of url: URL, scheme: String) -> Int? {
        url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
    }
}

/// When each host last answered, so the probe runs once per host per check.
private actor ReachedHosts {
    private var answered: [String: any InstantProtocol<Duration>] = [:]

    func answered(_ key: String, within reuse: Duration, now: any InstantProtocol<Duration>) -> Bool {
        guard let last = answered[key], let elapsed = last.duration(toAny: now) else {
            return false
        }
        return elapsed < reuse
    }

    func record(_ key: String, now: any InstantProtocol<Duration>) {
        answered[key] = now
    }

    func forget(_ key: String) {
        answered[key] = nil
    }
}

extension InstantProtocol where Duration == Swift.Duration {
    /// The duration to another instant of the same clock; nil for an instant of another type.
    fileprivate func duration(toAny other: any InstantProtocol<Swift.Duration>) -> Swift.Duration? {
        (other as? Self).map { duration(to: $0) }
    }
}
