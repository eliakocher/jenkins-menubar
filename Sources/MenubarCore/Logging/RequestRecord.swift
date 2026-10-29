import Foundation

/// A request with its response, kept for the details of its log entry (LOG-02).
///
/// Every initializer applies the rules, so no record can hold a secret: of the request, only the scheme of its
/// `Authorization` header is kept, and of the response, the headers without `Set-Cookie` (any case) and the first
/// `bodyLimit` bytes of the body.
public struct RequestRecord: Codable, Sendable, Hashable {
    public struct Header: Codable, Sendable, Hashable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// The scheme of the request's `Authorization` header. The credentials are never kept.
    public enum Authorization: String, Codable, Sendable, Hashable {
        case basic = "Basic"
        case bearer = "Bearer"

        /// the environment variable "Copy as cURL" puts in place of the token
        public var tokenVariable: String {
            switch self {
            case .basic: TokenAccount.jenkins.rawValue
            case .bearer: TokenAccount.gitlab.rawValue
            }
        }
    }

    /// 128 KB
    public static let defaultBodyLimit = 131_072

    public var method: String
    /// the URL as sent, without any user or password
    public var url: String
    public var authorization: Authorization?
    /// the GraphQL operation's name, for GitLab requests
    public var operationName: String?
    /// the GraphQL query
    public var query: String?
    /// the GraphQL variables as JSON text, keys in their order
    public var variables: String?
    /// the HTTP status, nil when no answer came
    public var status: Int?
    /// why no answer came, in the words of NET-01
    public var error: String?
    public var seconds: Double
    /// the response headers, sorted by name, without `Set-Cookie`
    public var headers: [Header]
    /// the size of the whole response body
    public var bytes: Int
    /// whether the body is only the first part of the response's
    public var truncated: Bool
    /// the first part of the response body, as UTF-8
    public var body: String

    public init(
        method: String,
        url: URL,
        authorization: Authorization? = nil,
        graphQL: GraphQLOperation? = nil,
        query: String? = nil,
        status: Int? = nil,
        error: String? = nil,
        seconds: Double,
        responseHeaders: [String: String] = [:],
        responseBody: Data = Data(),
        bodyLimit: Int = defaultBodyLimit
    ) {
        self.method = method
        self.url = Self.withoutCredentials(url)
        self.authorization = authorization
        self.operationName = graphQL?.name
        self.query = query
        self.variables = graphQL?.variables
        self.status = status
        self.error = error
        self.seconds = seconds
        self.headers = responseHeaders
            .filter { !$0.key.lowercased().hasPrefix("set-cookie") }
            .map { Header(name: $0.key, value: $0.value) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        self.bytes = responseBody.count
        self.truncated = responseBody.count > bodyLimit
        self.body = String(decoding: responseBody.prefix(bodyLimit), as: UTF8.self)
    }

    /// The record of a request that was answered, or of one that failed with `error`.
    public init(request: HTTPRequest, response: HTTPResponse?, error: String? = nil, seconds: Double, bodyLimit: Int = defaultBodyLimit) {
        self.init(
            method: request.method,
            url: request.url,
            authorization: Self.authorization(of: request),
            graphQL: request.graphQL,
            query: request.graphQL == nil ? nil : Self.query(in: request.body),
            status: response?.status,
            error: error,
            seconds: seconds,
            responseHeaders: response?.headers ?? [:],
            responseBody: response?.body ?? Data(),
            bodyLimit: bodyLimit
        )
    }

    /// The request as a curl command, with the token as `$JENKINS_MCP_BASIC_AUTH` or `$GITLAB_TOKEN`, so it can be run
    /// after exporting it (LOG-02).
    public var curlCommand: String {
        var parts = ["curl"]
        if method != "GET" {
            parts += ["-X", method]
        }
        if let authorization {
            parts += ["-H", "\"Authorization: \(authorization.rawValue) $\(authorization.tokenVariable)\""]
        }
        if let query {
            parts += ["-H", Self.shellQuoted("Content-Type: application/json"), "--data", Self.shellQuoted(Self.graphQLBody(query: query, variables: variables))]
        }
        parts.append(Self.shellQuoted(url))
        return parts.joined(separator: " ")
    }

    /// The body indented as JSON, keys in their order, also when it was cut: the indenting stops where the text does.
    /// Nil when the body isn't JSON.
    public var indentedBody: String? {
        styledBody?.text
    }

    /// The body indented as JSON with the kinds of its tokens; nil when the body isn't JSON.
    public var styledBody: StyledText? {
        JSONIndenter.indent(body)
    }

    /// JSON text indented by two spaces, keeping the keys in their order, which `JSONSerialization` doesn't. The text
    /// may be cut anywhere; nil when it isn't JSON, like a page of HTML.
    public static func indentedJSON(_ text: String) -> String? {
        JSONIndenter.indent(text)?.text
    }

    private static func authorization(of request: HTTPRequest) -> Authorization? {
        guard let value = request.headers.first(where: { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame })?.value else {
            return nil
        }
        let scheme = value.prefix { $0 != " " }
        return [Authorization.basic, .bearer].first { $0.rawValue.caseInsensitiveCompare(scheme) == .orderedSame }
    }

    /// The `query` of a GraphQL body: `{"query": …, "variables": …}`.
    private static func query(in body: Data?) -> String? {
        struct Body: Decodable {
            var query: String
        }
        return body.flatMap { try? JSONDecoder().decode(Body.self, from: $0).query }
    }

    private static func withoutCredentials(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.user != nil || components.password != nil else {
            return url.absoluteString
        }
        components.user = nil
        components.password = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    private static func graphQLBody(query: String, variables: String?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let quotedQuery = (try? encoder.encode(query)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return "{\"query\":\(quotedQuery),\"variables\":\(variables ?? "{}")}"
    }

    /// The text in single quotes for a shell, a single quote in it written as `'\''`.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
