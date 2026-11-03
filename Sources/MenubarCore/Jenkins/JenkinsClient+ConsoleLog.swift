import Foundation

/// One answer of Jenkins's `logText/progressiveText`: a build's console log from a byte offset (PIPE-12).
///
/// From the Jenkins and Stapler sources (`LargeText.doProgressText`, `AnnotatedLargeText`), not from a real server:
/// - `start` counts the bytes of the stored log, which holds Jenkins's hidden console notes; the text sent has them
///   taken out, so it is shorter than the offsets it spans, and no offset can be computed from the text.
/// - The answer always runs to the log's current end; there is no end parameter. A start past the end starts over at 0.
/// - `X-Text-Size` is the stored size when Jenkins answered: the start of the request that follows the end.
/// - `X-More-Data: true` while the build still writes; without it the log is complete.
public struct ConsoleLogChunk: Sendable, Hashable {
    /// the offset asked, in the stored log's bytes
    public var start: Int64
    /// the text from there, as Jenkins sent it: up to the limit, or to the log's end
    public var body: Data
    /// `X-Text-Size`, the stored log's size when Jenkins answered
    public var size: Int64
    /// whether the log may still grow (`X-More-Data`)
    public var hasMore: Bool
    /// whether the body stopped at the limit, before the log's end
    public var isCut: Bool

    public init(start: Int64, body: Data, size: Int64, hasMore: Bool, isCut: Bool) {
        self.start = start
        self.body = body
        self.size = size
        self.hasMore = hasMore
        self.isCut = isCut
    }
}

extension JenkinsClient {
    /// Returns a build's console log from a byte offset, at most `limit` bytes of it (PIPE-12).
    ///
    /// The transport drops the connection once it has `limit` bytes, so a page from early in a long log doesn't bring
    /// the rest of it. The text is never kept with the request in the captured requests, and never logged.
    ///
    /// - Parameters:
    ///   - job: the job's name as in Jenkins URLs
    ///   - number: the build number
    ///   - start: the offset in the stored log, from ``ConsoleLogChunk/size`` or 0
    ///   - limit: the most bytes read; nil reads to the log's end
    /// - Returns: the text and the log's size
    public func consoleLog(job: String, number: Int, from start: Int64, limit: Int?) async throws -> ConsoleLogChunk {
        var root = jobURL.absoluteString
        while root.hasSuffix("/") {
            root.removeLast()
        }
        let path = "/job/\(Self.safe(job))/\(number)/logText/progressiveText?start=\(max(0, start))"
        guard let url = URL(string: root + path) else {
            throw JenkinsError(.gone)
        }
        let request = HTTPRequest(
            url: url, headers: ["Authorization": "Basic \(token)"], timeout: timeouts.jenkinsJobList, bodyLimit: limit,
            keepsBody: false)
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw JenkinsError(.unreachable(.jenkins))
        }
        switch response.status {
        case 200..<300: break
        case 401, 403: throw JenkinsError(.rejectedToken(.jenkins))
        case 404: throw JenkinsError(.gone)
        default: throw JenkinsError(.httpStatus(.jenkins, status: response.status))
        }
        var body = response.body
        var isCut = false
        if let limit, body.count >= limit {
            body = body.prefix(limit)
            isCut = true
        }
        // Without the header, as from a proxy that drops it, the text's own length is the best guess.
        let size = response.header("X-Text-Size").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
            ?? start + Int64(body.count)
        let hasMore = response.header("X-More-Data")?.trimmingCharacters(in: .whitespaces).lowercased() == "true"
        return ConsoleLogChunk(start: start, body: body, size: size, hasMore: hasMore, isCut: isCut)
    }
}
