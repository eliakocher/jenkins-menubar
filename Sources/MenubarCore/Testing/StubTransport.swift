#if DEBUG
import Foundation

/// An `HTTPTransport` for tests and the gallery: it answers from routes, after a delay on its clock, and keeps every
/// request it got. Debug builds only.
///
/// ```swift
/// let clock = TestClock()
/// let stub = StubTransport(clock: clock)
/// stub.answer(path: "/job/project/api/json", body: #"{"jobs": []}"#)
/// stub.answer(operation: "WorkItems", after: .seconds(2), body: workItemsJSON)
/// stub.fail(path: "/job/project/job/MR-1/api/json", with: .unknownHost)
/// ```
///
/// The newest route that matches answers, so a test can override an earlier route, or put a route with `times: 1` in
/// front of it. A delay longer than the request's time limit ends the way `URLSessionTransport` does: after the limit,
/// with `TransportError.noAnswer`. A request no route matches throws `TransportError.other`, naming the request.
public final class StubTransport: HTTPTransport, @unchecked Sendable {
    /// One way to answer: which requests it takes, after how long, how often, and with what.
    public struct Route: Sendable {
        /// whether the route takes a request
        public var matches: @Sendable (HTTPRequest) -> Bool
        /// how long the answer takes on the stub's clock
        public var delay: Duration
        /// how many requests the route answers; nil for any number
        public var times: Int?
        /// the answer, or the error to throw
        public var reply: @Sendable (HTTPRequest) -> Result<HTTPResponse, TransportError>

        public init(
            matches: @escaping @Sendable (HTTPRequest) -> Bool,
            delay: Duration = .zero,
            times: Int? = nil,
            reply: @escaping @Sendable (HTTPRequest) -> Result<HTTPResponse, TransportError>
        ) {
            self.matches = matches
            self.delay = delay
            self.times = times
            self.reply = reply
        }
    }

    private let clock: any Clock<Duration>
    private let lock = NSLock()
    private var routes: [Route] = []
    private var received: [HTTPRequest] = []

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// every request the stub got, oldest first, including those still waiting for their answer
    public var requests: [HTTPRequest] {
        lock.withLock { received }
    }

    /// Returns the requests to a path.
    ///
    /// - Parameter path: the URL's path as it appears in the URL, percent-encoded and without the query
    /// - Returns: the requests to that path, oldest first
    public func requests(path: String) -> [HTTPRequest] {
        requests.filter { $0.url.path(percentEncoded: true) == path }
    }

    /// Returns the requests of a GraphQL operation.
    ///
    /// - Parameter operation: the operation name, such as `WorkItems`
    /// - Returns: the requests of that operation, oldest first
    public func requests(operation: String) -> [HTTPRequest] {
        requests.filter { $0.graphQL?.name == operation }
    }

    /// Adds a route; the newest route that matches a request answers it.
    ///
    /// - Parameter route: the route
    public func add(_ route: Route) {
        lock.withLock {
            routes.append(route)
        }
    }

    /// Adds a route that answers with an HTTP response. A route without a method, path or operation takes any.
    ///
    /// - Parameters:
    ///   - method: the HTTP method, such as `GET`
    ///   - path: the URL's path as it appears in the URL, percent-encoded and without the query
    ///   - operation: the GraphQL operation name
    ///   - delay: how long the answer takes on the stub's clock
    ///   - times: how many requests the route answers; nil for any number
    ///   - status: the HTTP status
    ///   - headers: the response headers
    ///   - body: the response body, as UTF-8
    public func answer(
        _ method: String? = nil,
        path: String? = nil,
        operation: String? = nil,
        after delay: Duration = .zero,
        times: Int? = nil,
        status: Int = 200,
        headers: [String: String] = [:],
        body: String = ""
    ) {
        let response = HTTPResponse(status: status, headers: headers, body: Data(body.utf8))
        add(Route(matches: Self.matcher(method, path, operation), delay: delay, times: times) { _ in .success(response) })
    }

    /// Adds a route that throws a transport error, like a host that is unknown, refuses or doesn't answer.
    ///
    /// - Parameters:
    ///   - method: the HTTP method, such as `GET`
    ///   - path: the URL's path as it appears in the URL, percent-encoded and without the query
    ///   - operation: the GraphQL operation name
    ///   - delay: how long the failure takes on the stub's clock
    ///   - times: how many requests the route answers; nil for any number
    ///   - error: the error to throw
    public func fail(
        _ method: String? = nil,
        path: String? = nil,
        operation: String? = nil,
        after delay: Duration = .zero,
        times: Int? = nil,
        with error: TransportError
    ) {
        add(Route(matches: Self.matcher(method, path, operation), delay: delay, times: times) { _ in .failure(error) })
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let route: Route? = lock.withLock {
            received.append(request)
            guard let index = routes.lastIndex(where: { $0.times != 0 && $0.matches(request) }) else {
                return nil
            }
            if let times = routes[index].times {
                routes[index].times = times - 1
            }
            return routes[index]
        }
        guard let route else {
            throw TransportError.other("StubTransport has no route for \(Self.describe(request))")
        }
        if route.delay > request.timeout {
            try await clock.sleep(for: request.timeout)
            throw TransportError.noAnswer(within: request.timeout)
        }
        if route.delay > .zero {
            try await clock.sleep(for: route.delay)
        }
        return try route.reply(request).get()
    }

    private static func matcher(_ method: String?, _ path: String?, _ operation: String?) -> @Sendable (HTTPRequest) -> Bool {
        { request in
            (method.map { $0.caseInsensitiveCompare(request.method) == .orderedSame } ?? true)
                && (path.map { $0 == request.url.path(percentEncoded: true) } ?? true)
                && (operation.map { $0 == request.graphQL?.name } ?? true)
        }
    }

    private static func describe(_ request: HTTPRequest) -> String {
        let operation = request.graphQL.map { " (\($0.name))" } ?? ""
        return "\(request.method) \(request.url.absoluteString)\(operation)"
    }
}
#endif
