import Foundation

/// One HTTP request, as a client builds it and a transport sends it.
public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    /// the request headers, `Authorization` included; the transport sends them as given
    public var headers: [String: String]
    public var body: Data?
    /// the most time the answer may take, after the connection probe passed (NET-01)
    public var timeout: Duration
    /// the GraphQL operation, for the logs; nil for Jenkins requests
    public var graphQL: GraphQLOperation?
    /// whether a 3xx answer is followed; `false` hands it over as it is, with its `Location`, as Jenkins's answer to a
    /// build request needs (PIPE-09)
    public var followsRedirects: Bool

    public init(
        method: String = "GET",
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: Duration,
        graphQL: GraphQLOperation? = nil,
        followsRedirects: Bool = true
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.graphQL = graphQL
        self.followsRedirects = followsRedirects
    }
}

/// The GraphQL operation a request carries in its body, kept apart so the logs can name it without parsing the body.
public struct GraphQLOperation: Sendable, Hashable {
    /// the operation name, such as `WorkItems`
    public var name: String
    /// the variables as JSON text, with the keys in the order the client wrote them
    public var variables: String

    public init(name: String, variables: String) {
        self.name = name
        self.variables = variables
    }
}

/// An HTTP answer, whatever its status. Failures without an answer are thrown as `TransportError`.
public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    /// the response headers, `Set-Cookie` included; `RequestRecorder` drops it before anything is kept
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The value of a header, whatever the case of its name.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Sends HTTP requests. `URLSessionTransport` talks to the servers, `StubTransport` answers in tests, and
/// `RequestRecorder` wraps either to log and capture each request.
public protocol HTTPTransport: Sendable {
    /// Sends a request and returns the answer, whatever its status.
    ///
    /// Throws `TransportError` when no answer came, and `CancellationError` when the calling task was cancelled.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
