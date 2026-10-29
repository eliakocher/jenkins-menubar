import Foundation

/// The texts of a kept request's details: Request, Response and Headers, and "Copy as cURL" (LOG-02, LOG-04).
///
/// None of them holds a token: the record keeps only the scheme of `Authorization`, and the curl command puts
/// `$JENKINS_MCP_BASIC_AUTH` or `$GITLAB_TOKEN` in its place.
public struct RequestDetails: Hashable, Sendable {
    public let record: RequestRecord

    public init(record: RequestRecord) {
        self.record = record
    }

    /// The request: the method and the decoded URL, the kind of authorization without its token, and for GitLab the
    /// query and its variables (unless `{}`).
    public var requestText: String {
        styledRequest.text
    }

    /// The request's text with the kinds of its parts: the method, the header names, "(not kept)" and the variables'
    /// JSON.
    public var styledRequest: StyledText {
        var builder = StyledTextBuilder()
        builder.append(record.method, kind: .httpMethod)
        builder.append(" \(record.url.removingPercentEncoding ?? record.url)")
        if let authorization = record.authorization {
            builder.append("\n")
            builder.append("Authorization", kind: .headerName)
            builder.append(": \(authorization.rawValue) ")
            builder.append("(not kept)", kind: .notKept)
        }
        if let query = record.query {
            builder.append("\n")
            builder.append("Content-Type", kind: .headerName)
            builder.append(": application/json\n\n\(query)")
        }
        if let variables = record.variables, variables != "{}" {
            builder.append("\n\n")
            builder.append("Variables", kind: .headerName)
            builder.append(": ")
            builder.append(JSONIndenter.indent(variables) ?? StyledText(text: variables))
        }
        return builder.result
    }

    /// The response: the status line and the body, as indented JSON when it is JSON, and what was cut; or why no
    /// answer came.
    public var responseText: String {
        styledResponse.text
    }

    /// The response's text with the kinds of its parts: the JSON body's tokens and the note about what was cut.
    public var styledResponse: StyledText {
        guard let status = record.status else {
            return StyledText(text: Self.noAnswer(record.error))
        }
        var builder = StyledTextBuilder()
        builder.append("HTTP \(status)")
        if !record.body.isEmpty {
            builder.append("\n\n")
            builder.append(record.styledBody ?? StyledText(text: record.body))
        }
        if record.truncated {
            builder.append("\n\n")
            builder.append("… only the first \(Self.size(record.body.utf8.count)) of \(Self.size(record.bytes)) are kept", kind: .note)
        }
        return builder.result
    }

    /// The response headers, one per line, without `Set-Cookie`.
    public var headersText: String {
        styledHeaders.text
    }

    /// The headers' text with the names as spans.
    public var styledHeaders: StyledText {
        guard record.status != nil else {
            return StyledText(text: "No headers: no answer.")
        }
        guard !record.headers.isEmpty else {
            return StyledText(text: "No headers.")
        }
        var builder = StyledTextBuilder()
        for (index, header) in record.headers.enumerated() {
            builder.append(index == 0 ? "" : "\n")
            builder.append(header.name, kind: .headerName)
            builder.append(": \(header.value)")
        }
        return builder.result
    }

    /// the request as a curl command for Terminal, with the token as an environment variable
    public var curlCommand: String {
        record.curlCommand
    }

    /// Returns the facts above the texts: the time, the seconds, and the size of the answer.
    ///
    /// - Parameters:
    ///   - time: the time of the request's log entry
    ///   - timeZone: the time zone of the time
    /// - Returns: the facts, like `09:12:03 · 0.25 s · 1 KB`
    public func facts(time: Date, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .standard)
        style.timeZone = timeZone
        var facts = [time.formatted(style), "\(record.seconds.formatted(.number.precision(.fractionLength(2)).locale(Self.posix))) s"]
        if record.status != nil {
            facts.append(Self.size(record.bytes))
        }
        return facts.joined(separator: " · ")
    }

    /// "No answer within 20 seconds", or "No answer: unknown host (VPN?)", from the NET-01 text the record keeps.
    static func noAnswer(_ error: String?) -> String {
        guard let error, !error.isEmpty else {
            return "No answer."
        }
        if error.hasPrefix("no answer") {
            return "N" + error.dropFirst()
        }
        return "No answer: \(error)"
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func size(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }
}

/// What the details of an Activity entry show (LOG-02, LOG-04).
public struct ActivityDetails: Hashable, Sendable {
    /// the text shown when the entry's request was dropped to make room for newer ones (LOG-03)
    public static let goneMessage = "The request and its response are gone: only the newest requests keep theirs."

    public let item: ActivityItem
    /// the kept request and its response; nil for an entry without a request, or when it is gone
    public let request: RequestDetails?

    public init(item: ActivityItem, request: RequestDetails?) {
        self.item = item
        self.request = request
    }

    /// whether the entry names a request that is no longer kept
    public var requestIsGone: Bool {
        item.hasRequest && request == nil
    }
}
