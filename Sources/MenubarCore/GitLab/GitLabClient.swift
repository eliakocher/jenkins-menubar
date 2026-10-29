import Foundation

/// Sends GraphQL operations to GitLab's API and turns the answers into values, or into the problems of MR-05.
///
/// Every operation is a JSON POST of `{"query": …, "variables": …}` to `<gitlab>/api/graphql`, with the token as
/// `Authorization: Bearer` and never in the URL (NET-02). Wrap the transport in a `RequestRecorder` to log the
/// requests under their operation names.
///
/// ```swift
/// let client = GitLabClient(transport: recorder, gitLab: url, token: token)
/// let me = try await client.send(.currentUser)
/// ```
public struct GitLabClient: Sendable {
    let transport: any HTTPTransport
    private let endpoint: URL
    /// `<gitlab>/api/v4`, for the few requests that GraphQL doesn't answer
    let restBase: URL
    let token: String
    let timeout: Duration

    /// - Parameters:
    ///   - transport: the transport that sends the requests
    ///   - gitLab: the GitLab instance, like `https://gitlab.example.com`
    ///   - token: the GitLab token, with the `api` scope (`read_api` reads, and can't write)
    ///   - timeouts: the time limits; every operation gets `gitLab`
    public init(transport: any HTTPTransport, gitLab: URL, token: String, timeouts: Timeouts = .standard) {
        self.transport = transport
        self.endpoint = gitLab.appending(path: "api/graphql")
        self.restBase = gitLab.appending(path: "api/v4")
        self.token = token
        self.timeout = timeouts.gitLab
    }

    /// Sends an operation and decodes its answer.
    ///
    /// The problems, in this order:
    /// - no answer: unreachable;
    /// - HTTP 401 or 403: a rejected token, or a missing scope when the answer says `insufficient_scope`;
    /// - another HTTP status: the operation's failure for that status;
    /// - an answer without the value: the GraphQL errors when there are some, otherwise the operation's failure.
    ///
    /// - Parameter operation: the operation, like ``GitLabOperation/currentUser``
    /// - Returns: the decoded value
    /// - Throws: ``GitLabError`` with the problem, or `CancellationError` when the calling task was cancelled
    public func send<Value>(_ operation: GitLabOperation<Value>) async throws -> Value {
        let response: HTTPResponse
        do {
            response = try await transport.send(request(for: operation))
        } catch is TransportError {
            throw GitLabError(.unreachable(.gitLab))
        }
        let errors = GraphQLErrors.messages(in: response.body)
        switch response.status {
        case 401, 403:
            throw GitLabError(Self.namesInsufficientScope(response) ? .missingScope : .rejectedToken(.gitLab))
        case 200..<300:
            do {
                return try operation.decode(response.body)
            } catch let error as GitLabError {
                throw error
            } catch {
                throw GitLabError(errors.isEmpty ? operation.failure(response.status, []) : .graphQLErrors(messages: errors))
            }
        default:
            throw GitLabError(operation.failure(response.status, errors))
        }
    }

    /// Returns the request that carries an operation.
    ///
    /// - Parameter operation: the operation
    /// - Returns: the POST to `<gitlab>/api/graphql`
    public func request<Value>(for operation: GitLabOperation<Value>) -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            url: endpoint,
            headers: [
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/json",
                "Accept": "application/json",
            ],
            body: Data(operation.body.utf8),
            timeout: timeout,
            graphQL: GraphQLOperation(name: operation.name, variables: operation.variables)
        )
    }

    /// Whether a refusal names the scope. GitLab's GraphQL endpoint answers a token without `read_api` or `api` with
    /// "Invalid token", so this only takes an OAuth error that says so: `{"error": "insufficient_scope"}`, or a
    /// `WWW-Authenticate` header with `error="insufficient_scope"`.
    private static func namesInsufficientScope(_ response: HTTPResponse) -> Bool {
        struct OAuthError: Decodable {
            var error: String
        }
        if response.header("WWW-Authenticate")?.contains("insufficient_scope") == true {
            return true
        }
        return (try? JSONDecoder().decode(OAuthError.self, from: response.body))?.error == "insufficient_scope"
    }
}

/// Why a GitLab operation gave no value: the problem to show and log (MR-05).
public struct GitLabError: Error, Hashable, Sendable, CustomStringConvertible {
    public var problem: Problem

    public init(_ problem: Problem) {
        self.problem = problem
    }

    public var description: String { problem.message }
}

/// The `errors` of a GraphQL answer.
enum GraphQLErrors {
    private struct Answer: Decodable {
        var errors: [Message]?
    }

    private struct Message: Decodable {
        var message: String
    }

    /// Returns the error messages of an answer, in GitLab's order.
    ///
    /// - Parameter body: the answer's body
    /// - Returns: the messages; empty when there are none, or the body isn't a GraphQL answer
    static func messages(in body: Data) -> [String] {
        (try? JSONDecoder().decode(Answer.self, from: body))?.errors?.map(\.message) ?? []
    }
}
