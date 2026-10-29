import Foundation

/// A parameter of a build, from Jenkins's `ParametersAction` (PIPE-09).
public struct BuildParameter: Hashable, Sendable {
    public var name: String
    /// the value as a form sends it: the text, `true` or `false`, or the number
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A build waiting in Jenkins's queue, as the answer that queued it names it: `Location: <Jenkins>/queue/item/<id>/`
/// (PIPE-09).
public struct QueueItem: Hashable, Sendable {
    /// the item's id, which `queue/cancelItem` takes
    public var id: Int

    public init(id: Int) {
        self.id = id
    }
}

/// Where a queued build stands, from `queue/item/<id>/api/json` (PIPE-09).
public enum QueueItemState: Hashable, Sendable {
    /// still in the queue: in its quiet period, or waiting for an executor
    case waiting
    /// it left the queue as this build of its job
    case started(number: Int)
    /// someone cancelled it before it started
    case cancelled
    /// Jenkins no longer knows it: it forgets an item a few minutes after the item left the queue
    case gone
}

/// Why a rebuild didn't start, or its queue item couldn't be cancelled, in plain words (PIPE-09).
public enum JenkinsRebuildError: Error, Hashable, Sendable, CustomStringConvertible {
    /// HTTP 403 for starting the job: the account lacks Jenkins's Build permission for it
    case noBuildPermission
    /// HTTP 404 for the job or the build
    case jobGone
    /// Jenkins answered without a queue item, as when its queue turned the build down
    case notQueued
    /// HTTP 403 or 422 for the cancel: the account may not cancel the queue item
    case notCancellable
    /// no token, missing team values, a rejected token, no answer or another status (JERR)
    case problem(Problem)

    /// the text the row shows and the log entry ends with, without a trailing period
    public var message: String {
        switch self {
        case .noBuildPermission: "Jenkins didn't allow the rebuild: your account lacks the Build permission"
        case .jobGone: "The job is gone"
        case .notQueued: "Jenkins didn't queue the rebuild"
        case .notCancellable: "Jenkins didn't allow cancelling the rebuild"
        case .problem(let problem): problem.message
        }
    }

    public var description: String { message }
}

extension JenkinsRebuildError: LocalizedError {
    public var errorDescription: String? { message }
}

/// The rebuild's requests (PIPE-09), with Jenkins's standard remote API: the build's parameters, the job's parameter
/// definitions, `buildWithParameters` or `build`, the queue item and `queue/cancelItem`.
///
/// Every failure is thrown as a ``JenkinsRebuildError``. The requests never follow a redirect: Jenkins answers a build
/// request with 201, or 303 for an item that was queued already, and its `Location` names the queue item.
///
/// Requests authenticated with an API token need no CSRF crumb (jenkins.io, CSRF Protection). When Jenkins asks for one
/// all the same, with 403 "No valid crumb was included in the request", the crumb is fetched from
/// `crumbIssuer/api/json` and the request is sent once more, with the crumb and the session cookie it belongs to.
extension JenkinsClient {
    /// Starts a build's job again with that build's parameters, not the job's defaults (PIPE-09).
    ///
    /// A job with parameter definitions gets `POST <job>/buildWithParameters`, with the build's parameters
    /// form-encoded; Jenkins takes the job's default for a parameter the build doesn't show a value for, like a
    /// password, and ignores one the job no longer defines. A job without parameters gets `POST <job>/build`.
    ///
    /// - Parameters:
    ///   - job: the job's name as in Jenkins URLs
    ///   - number: the build to start again
    /// - Returns: the queue item the new build waits in
    public func rebuild(job: String, number: Int) async throws -> QueueItem {
        let parameters = try await rebuildStep { try await self.parameters(job: job, number: number) }
        let parameterized = try await rebuildStep { try await self.isParameterized(job: job) }
        let page = parameterized ? "buildWithParameters" : "build"
        let response = try await post(jobPage(job, page), form: parameterized ? Self.form(parameters) : nil)
        switch response.status {
        case 200..<400:
            guard let item = response.header("Location").flatMap(Self.queueItem(location:)) else {
                throw JenkinsRebuildError.notQueued
            }
            return item
        case 401: throw JenkinsRebuildError.problem(.rejectedToken(.jenkins))
        case 403: throw JenkinsRebuildError.noBuildPermission
        case 404: throw JenkinsRebuildError.jobGone
        default: throw JenkinsRebuildError.problem(.httpStatus(.jenkins, status: response.status))
        }
    }

    /// Returns a build's parameters, from `actions[parameters[name,value]]`; a parameter without a value Jenkins
    /// shows, like a password or a file, is left out.
    ///
    /// - Parameters:
    ///   - job: the job's name as in Jenkins URLs
    ///   - number: the build number
    /// - Returns: the parameters, in Jenkins's order; empty for a build without any
    public func parameters(job: String, number: Int) async throws -> [BuildParameter] {
        let answer: ParametersAnswer = try await get(
            "/job/\(Self.safe(job))/\(number)/api/json?tree=actions%5Bparameters%5Bname,value%5D%5D",
            timeout: timeouts.jenkins, notFound: .gone, timedOut: .unreachable(.jenkins))
        var parameters: [BuildParameter] = []
        for parameter in (answer.actions ?? []).compactMap({ $0?.parameters }).joined().compactMap({ $0 }) {
            guard let name = parameter.name, !name.isEmpty, let value = parameter.value?.text,
                !parameters.contains(where: { $0.name == name })
            else { continue }
            parameters.append(BuildParameter(name: name, value: value))
        }
        return parameters
    }

    /// Returns whether a job defines parameters, from `property[parameterDefinitions[name]]`; a multibranch job's
    /// first build may have none while the job has some since.
    ///
    /// - Parameter job: the job's name as in Jenkins URLs
    /// - Returns: `true` when the job has a parameter definition
    public func isParameterized(job: String) async throws -> Bool {
        let answer: DefinitionsAnswer = try await get(
            "/job/\(Self.safe(job))/api/json?tree=property%5BparameterDefinitions%5Bname%5D%5D",
            timeout: timeouts.jenkins, notFound: .gone, timedOut: .unreachable(.jenkins))
        return (answer.property ?? []).contains { !($0?.parameterDefinitions ?? []).compactMap { $0 }.isEmpty }
    }

    /// Asks where a queued build stands.
    ///
    /// - Parameter item: the queue item
    /// - Returns: waiting, started with its number, cancelled, or gone once Jenkins forgot the item
    public func state(of item: QueueItem) async throws -> QueueItemState {
        let response = try await send(
            "GET", jenkinsPage("queue/item/\(item.id)/api/json?tree=cancelled,executable%5Bnumber%5D"))
        switch response.status {
        case 200..<300:
            guard let answer = try? JSONDecoder().decode(QueueItemAnswer.self, from: response.body) else {
                throw JenkinsRebuildError.problem(.notJSON)
            }
            if answer.cancelled == true {
                return .cancelled
            }
            // A left item gets its build a moment after it left: until then it counts as waiting.
            return answer.executable?.number.map { .started(number: $0) } ?? .waiting
        case 401, 403: throw JenkinsRebuildError.problem(.rejectedToken(.jenkins))
        case 404: return .gone
        default: throw JenkinsRebuildError.problem(.httpStatus(.jenkins, status: response.status))
        }
    }

    /// Removes a queued build from the queue, with `POST <Jenkins>/queue/cancelItem?id=<id>`.
    ///
    /// - Parameter item: the queue item
    /// - Returns: `true` when it was removed; `false` when Jenkins no longer had it in the queue, because it started
    public func cancel(_ item: QueueItem) async throws -> Bool {
        let response = try await post(jenkinsPage("queue/cancelItem?id=\(item.id)"), form: nil)
        switch response.status {
        // 204 now; older Jenkins redirected to the queue.
        case 200..<400: return true
        case 404: return false
        case 401: throw JenkinsRebuildError.problem(.rejectedToken(.jenkins))
        case 403, 422: throw JenkinsRebuildError.notCancellable
        default: throw JenkinsRebuildError.problem(.httpStatus(.jenkins, status: response.status))
        }
    }

    /// Jenkins's root, where the queue and the crumb issuer are: the job URL up to its first `/job/`, with a trailing
    /// `/`, like `https://jenkins.example.com/` or `https://example.com/jenkins/`.
    var jenkinsRoot: URL {
        guard var components = URLComponents(url: jobURL, resolvingAgainstBaseURL: false) else {
            return jobURL
        }
        let path = components.percentEncodedPath
        components.percentEncodedPath = path.range(of: "/job/").map { String(path[..<$0.lowerBound]) + "/" } ?? "/"
        components.query = nil
        components.fragment = nil
        return components.url ?? jobURL
    }

    /// Returns the queue item a build request's `Location` names, relative or absolute.
    ///
    /// - Parameter location: the header's value, like `https://jenkins.example.com/queue/item/42/`
    /// - Returns: the item; `nil` when the header names none, as Jenkins's redirect to the job without a queue item
    static func queueItem(location: String) -> QueueItem? {
        guard let range = location.range(of: #"queue/item/[0-9]+"#, options: .regularExpression),
            let id = Int(location[range].dropFirst("queue/item/".count))
        else { return nil }
        return QueueItem(id: id)
    }

    /// Returns parameters as a form body, `name=value&…`, everything but the unreserved characters percent-encoded.
    static func form(_ parameters: [BuildParameter]) -> String {
        parameters.map { "\(formEncoded($0.name))=\(formEncoded($0.value))" }.joined(separator: "&")
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func formEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// Runs one of the client's GET requests and turns its `JenkinsError` into the rebuild's.
    private func rebuildStep<Value>(_ request: () async throws -> Value) async throws -> Value {
        do {
            return try await request()
        } catch let error as JenkinsError {
            throw error.problem == .gone ? JenkinsRebuildError.jobGone : JenkinsRebuildError.problem(error.problem)
        }
    }

    /// `<job URL>/job/<job>/<page>`
    private func jobPage(_ job: String, _ page: String) -> URL {
        var root = jobURL.absoluteString
        while root.hasSuffix("/") {
            root.removeLast()
        }
        return URL(string: "\(root)/job/\(Self.safe(job))/\(page)") ?? jobURL
    }

    /// `<Jenkins>/<page>`
    private func jenkinsPage(_ pageAndQuery: String) -> URL {
        URL(string: jenkinsRoot.absoluteString + pageAndQuery) ?? jenkinsRoot
    }

    /// Posts, and when Jenkins asks for a CSRF crumb, posts once more with one.
    private func post(_ url: URL, form: String?) async throws -> HTTPResponse {
        let response = try await send("POST", url, form: form)
        guard response.status == 403, String(decoding: response.body, as: UTF8.self).contains("No valid crumb") else {
            return response
        }
        return try await send("POST", url, form: form, headers: try await crumb())
    }

    /// Returns the crumb's header and the cookie of the session the crumb belongs to.
    private func crumb() async throws -> [String: String] {
        let url = jenkinsPage("crumbIssuer/api/json")
        let response = try await send("GET", url)
        guard (200..<300).contains(response.status),
            let answer = try? JSONDecoder().decode(CrumbAnswer.self, from: response.body),
            let crumb = answer.crumb, let field = answer.crumbRequestField, !field.isEmpty
        else {
            throw JenkinsRebuildError.problem(.httpStatus(.jenkins, status: 403))
        }
        // The transport keeps no cookies, so the session's cookie goes along by hand.
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: response.headers, for: url)
        return HTTPCookie.requestHeaderFields(with: cookies).merging([field: crumb]) { $1 }
    }

    /// Sends a request with the token in its `Authorization` header, never following a redirect, and returns the
    /// answer, whatever its status.
    private func send(_ method: String, _ url: URL, form: String? = nil, headers extra: [String: String] = [:])
        async throws -> HTTPResponse
    {
        var headers = extra
        headers["Authorization"] = "Basic \(token)"
        var body: Data?
        if let form {
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            body = Data(form.utf8)
        }
        let request = HTTPRequest(
            method: method, url: url, headers: headers, body: body, timeout: timeouts.jenkins, followsRedirects: false)
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw JenkinsRebuildError.problem(.unreachable(.jenkins))
        }
    }
}

// The answers, read leniently, as the client's others.

private struct ParametersAnswer: Decodable {
    struct Action: Decodable {
        var parameters: [Parameter?]?
    }

    struct Parameter: Decodable {
        var name: String?
        var value: Value?
    }

    /// A parameter's value as a form sends it; `nil` for one that isn't text, a truth value or a number, like a run.
    struct Value: Decodable {
        var text: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self.text = text
            } else if let flag = try? container.decode(Bool.self) {
                text = flag ? "true" : "false"
            } else if let number = try? container.decode(Int.self) {
                text = String(number)
            } else if let number = try? container.decode(Double.self) {
                text = String(number)
            } else {
                text = nil
            }
        }
    }

    var actions: [Action?]?
}

private struct DefinitionsAnswer: Decodable {
    struct Property: Decodable {
        struct Definition: Decodable {
            var name: String?
        }

        var parameterDefinitions: [Definition?]?
    }

    var property: [Property?]?
}

private struct QueueItemAnswer: Decodable {
    struct Executable: Decodable {
        var number: Int?
    }

    var cancelled: Bool?
    var executable: Executable?
}

private struct CrumbAnswer: Decodable {
    var crumb: String?
    var crumbRequestField: String?
}
