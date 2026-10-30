import Foundation

extension JenkinsClient {
    /// the most of a console log scanned: its end, when it is longer
    static let consoleScanBytes = 32 * 1024 * 1024

    /// Returns a failed build's console log narrowed to its error markers, for "Why Did It Fail?" (AI-02;
    /// ``FailureLog/narrow(_:)``).
    ///
    /// Jenkins's `consoleText` has no ranges, so the whole log is read once, with the job list's longer time limit; a
    /// log longer than ``consoleScanBytes`` is scanned from that far before its end, from the start of a line.
    ///
    /// - Parameters:
    ///   - job: the job's name as in Jenkins URLs
    ///   - number: the build number
    /// - Returns: the narrowed log
    public func failureLog(job: String, number: Int) async throws -> FailureLog {
        let body = try await getText("/job/\(Self.safe(job))/\(number)/consoleText", timeout: timeouts.jenkinsJobList)
        let cut = body.count > Self.consoleScanBytes
        var text = String(decoding: cut ? body.suffix(Self.consoleScanBytes) : body[...], as: UTF8.self)
        if cut, let lineBreak = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: lineBreak)...])
        }
        return FailureLog.narrow(text)
    }

    /// Returns the commits since the job's last green build, up to and with a build, newest first (AI-02).
    ///
    /// One request with a `tree`: the last successful build's number and the recent builds' `changeSets` (a pipeline
    /// job) or `changeSet` (a freestyle job), each item's commit, message and author. The builds after the last green one
    /// and up to `number` give the changes; without a green build among them, the given build's own changes.
    ///
    /// - Parameters:
    ///   - job: the job's name as in Jenkins URLs
    ///   - number: the failed build
    ///   - limit: how many recent builds Jenkins lists
    /// - Returns: the changes, newest first, and the last green build's number
    public func changesSinceLastGreen(job: String, number: Int, limit: Int = 30) async throws -> (changes: [BuildChange], lastGreen: Int?) {
        let items = "items[commitId,msg,author[fullName]]"
        let tree = "lastSuccessfulBuild[number],builds[number,changeSets[\(items)],changeSet[\(items)]]{0,\(limit)}"
        let encoded = tree.replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")
            .replacingOccurrences(of: "{", with: "%7B").replacingOccurrences(of: "}", with: "%7D")
        let answer: ChangesAnswer = try await get(
            "/job/\(Self.safe(job))/api/json?tree=" + encoded,
            timeout: timeouts.jenkins, notFound: .gone, timedOut: .unreachable(.jenkins))
        let green = answer.lastSuccessfulBuild?.number.flatMap { $0 < number ? $0 : nil }
        let builds = (answer.builds ?? []).compactMap { $0 }
            .filter { build in
                guard let built = build.number else { return false }
                return built <= number && (green.map { built > $0 } ?? (built == number))
            }
            .sorted { ($0.number ?? 0) > ($1.number ?? 0) }
        let changes = builds.flatMap { build in
            ((build.changeSets ?? []) + [build.changeSet]).compactMap { $0 }.flatMap { set in
                (set.items ?? []).compactMap { item -> BuildChange? in
                    guard let item else { return nil }
                    return BuildChange(
                        commit: item.commitId ?? "", author: item.author?.fullName ?? "Someone",
                        message: ClaudePrompt.firstLine(item.msg ?? ""), build: build.number ?? number)
                }
                // A set lists its commits oldest first.
                .reversed()
            }
        }
        return (changes, green)
    }

    /// Sends a GET and returns the body as it is, mapping the failures as ``get(_:timeout:notFound:timedOut:)`` does.
    private func getText(_ pathAndQuery: String, timeout: Duration) async throws -> Data {
        var root = jobURL.absoluteString
        while root.hasSuffix("/") {
            root.removeLast()
        }
        guard let url = URL(string: root + pathAndQuery) else {
            throw JenkinsError(.gone)
        }
        let request = HTTPRequest(url: url, headers: ["Authorization": "Basic \(token)"], timeout: timeout)
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch TransportError.noAnswer {
            throw JenkinsError(.unreachable(.jenkins))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw JenkinsError(.unreachable(.jenkins))
        }
        switch response.status {
        case 200..<300: return response.body
        case 401, 403: throw JenkinsError(.rejectedToken(.jenkins))
        case 404: throw JenkinsError(.gone)
        default: throw JenkinsError(.httpStatus(.jenkins, status: response.status))
        }
    }
}

private struct ChangesAnswer: Decodable {
    struct Number: Decodable {
        var number: Int?
    }

    struct Author: Decodable {
        var fullName: String?
    }

    struct Item: Decodable {
        var commitId: String?
        var msg: String?
        var author: Author?
    }

    struct ChangeSet: Decodable {
        var items: [Item?]?
    }

    struct Build: Decodable {
        var number: Int?
        var changeSets: [ChangeSet?]?
        var changeSet: ChangeSet?
    }

    var lastSuccessfulBuild: Number?
    var builds: [Build?]?
}
