import Foundation
import Testing

@testable import MenubarCore

@Suite("RequestCapture")
struct RequestCaptureTests {
    private static let jenkinsToken = "amRvZTpzZWNyZXQtYXBpLXRva2Vu"
    private static let gitLabToken = "glpat-SecretToken_123"

    @Test("LOG-02 keeps a request with its response but no token or cookie")
    func keepsNoTokenOrCookie() async throws {
        let folder = try TemporaryFolder()
        let capture = RequestCapture(folder: folder.url)
        let request = HTTPRequest(
            url: URL(string: "https://jdoe:password@jenkins.example.com/job/project/api/json?depth=1")!,
            headers: ["Authorization": "Basic \(Self.jenkinsToken)", "Cookie": "JSESSIONID=sent-cookie"],
            timeout: .seconds(20)
        )
        let response = HTTPResponse(
            status: 200,
            headers: ["Content-Type": "application/json", "Set-Cookie": "JSESSIONID=abc123", "set-cookie": "other=def456", "X-Jenkins": "2.4"],
            body: Data(#"{"jobs":[]}"#.utf8)
        )

        let id = try #require(await capture.save(RequestRecord(request: request, response: response, seconds: 0.25)))

        let text = try folder.read("\(id).json")
        for secret in [Self.jenkinsToken, "password", "sent-cookie", "abc123", "def456"] {
            #expect(!text.contains(secret), "\(secret) was kept")
        }
        let record = try #require(await capture.record(id: id))
        #expect(record.method == "GET")
        #expect(record.url == "https://jenkins.example.com/job/project/api/json?depth=1")
        #expect(record.authorization == .basic)
        #expect(record.status == 200)
        #expect(record.seconds == 0.25)
        #expect(record.headers == [.init(name: "Content-Type", value: "application/json"), .init(name: "X-Jenkins", value: "2.4")])
        #expect(record.body == #"{"jobs":[]}"#)
        #expect(record.bytes == 11 && !record.truncated)
    }

    @Test("LOG-02 keeps the GraphQL query and variables")
    func keepsTheQuery() throws {
        let query = "query WorkItems($fullPath: ID!) { project(fullPath: $fullPath) { id } }"
        let variables = #"{"fullPath":"group/project","first":50}"#
        let request = HTTPRequest(
            method: "POST",
            url: URL(string: "https://gitlab.example.com/api/graphql")!,
            headers: ["Authorization": "Bearer \(Self.gitLabToken)", "Content-Type": "application/json"],
            body: Data(#"{"query":"\#(query)","variables":\#(variables)}"#.utf8),
            timeout: .seconds(30),
            graphQL: GraphQLOperation(name: "WorkItems", variables: variables)
        )

        let record = RequestRecord(request: request, response: nil, error: "no answer within 30 seconds", seconds: 30)

        #expect(record.operationName == "WorkItems")
        #expect(record.query == query)
        #expect(record.variables == variables)
        #expect(record.authorization == .bearer)
        #expect(record.status == nil && record.error == "no answer within 30 seconds")
    }

    @Test("LOG-02 keeps the first 128 KB of a big response")
    func keepsTheStart() throws {
        #expect(RequestRecord.defaultBodyLimit == 131_072)
        let body = Data(repeating: UInt8(ascii: "a"), count: 200_000)

        let record = RequestRecord(method: "GET", url: URL(string: "https://jenkins.example.com/api/json")!, status: 200, seconds: 1, responseBody: body)

        #expect(record.bytes == 200_000)
        #expect(record.truncated)
        #expect(record.body.utf8.count == 131_072)
        #expect(record.indentedBody == nil)
    }

    @Test("LOG-02 copy as curl leaves the token out")
    func curlLeavesTheTokenOut() throws {
        let jenkins = RequestRecord(request: HTTPRequest(
            url: URL(string: "https://jenkins.example.com/job/project/api/json?depth=1")!,
            headers: ["Authorization": "Basic \(Self.jenkinsToken)"],
            timeout: .seconds(20)
        ), response: nil, seconds: 0)
        #expect(jenkins.curlCommand == #"curl -H "Authorization: Basic $JENKINS_MCP_BASIC_AUTH" 'https://jenkins.example.com/job/project/api/json?depth=1'"#)

        let gitLab = RequestRecord(request: HTTPRequest(
            method: "POST",
            url: URL(string: "https://gitlab.example.com/api/graphql")!,
            headers: ["Authorization": "Bearer \(Self.gitLabToken)"],
            body: Data(#"{"query":"query { project(fullPath: \"it's\") { id } }","variables":{}}"#.utf8),
            timeout: .seconds(30),
            graphQL: GraphQLOperation(name: "Project", variables: "{}")
        ), response: nil, seconds: 0)
        #expect(gitLab.curlCommand == #"curl -X POST -H "Authorization: Bearer $GITLAB_TOKEN" -H 'Content-Type: application/json' --data '{"query":"query { project(fullPath: \"it'\''s\") { id } }","variables":{}}' 'https://gitlab.example.com/api/graphql'"#)
        #expect(!gitLab.curlCommand.contains(Self.gitLabToken) && !jenkins.curlCommand.contains(Self.jenkinsToken))
    }

    @Test("LOG-02 indents JSON keeping the key order")
    func indentsJSON() {
        let json = #"{"z":1, "a":[1,2,{"b":"x,y:{[\"}"}],"e":{},"f":[ ],"g":"é"}"#
        #expect(RequestRecord.indentedJSON(json) == """
            {
              "z": 1,
              "a": [
                1,
                2,
                {
                  "b": "x,y:{[\\"}"
                }
              ],
              "e": {},
              "f": [],
              "g": "é"
            }
            """)
        #expect(RequestRecord.indentedJSON("<html>not JSON</html>") == nil)
        #expect(RequestRecord.indentedJSON(#""just a string""#) == #""just a string""#)
    }

    @Test("LOG-02 tells when a request is gone")
    func requestIsGone() async throws {
        let folder = try TemporaryFolder()
        let capture = RequestCapture(folder: folder.url, maxFiles: 2, now: Self.ticking())

        let first = try #require(await capture.save(Self.record()))
        let second = try #require(await capture.save(Self.record()))
        let third = try #require(await capture.save(Self.record()))

        #expect(await capture.record(id: first) == nil)
        #expect(await capture.record(id: second) != nil)
        #expect(await capture.record(id: third) != nil)
        #expect(await capture.record(id: "../../etc/passwd") == nil)
    }

    @Test("LOG-03 keeps only the newest requests that fit in 10 MB")
    func keepsTheNewestThatFit() async throws {
        #expect(RequestCapture.defaultMaxBytes == 10_485_760)
        let folder = try TemporaryFolder()
        let size = try await Self.fileSize(of: Self.record(body: 1000))
        // Room for three and a half: the fourth newest doesn't fit.
        let capture = RequestCapture(folder: folder.url, maxBytes: size * 7 / 2 + 200, now: Self.ticking())

        var ids: [String] = []
        for _ in 1...6 {
            ids.append(try #require(await capture.save(Self.record(body: 1000))))
        }

        #expect(folder.contents() == ids.suffix(3).map { "\($0).json" })
        #expect(await capture.totalBytes() <= size * 7 / 2 + 200)

        // A new capture over the same folder goes on from what is there.
        let again = RequestCapture(folder: folder.url, maxBytes: size * 7 / 2 + 200, now: Self.ticking(from: 100))
        let newest = try #require(await again.save(Self.record(body: 1000)))
        #expect(folder.contents() == (ids.suffix(2) + [newest]).map { "\($0).json" })
    }

    @Test("LOG-03 keeps at most 1000 requests")
    func keepsAtMost1000() async throws {
        #expect(RequestCapture.defaultMaxFiles == 1000)
        let folder = try TemporaryFolder()
        let capture = RequestCapture(folder: folder.url, now: Self.ticking())

        var ids: [String] = []
        for _ in 1...1003 {
            ids.append(try #require(await capture.save(Self.record())))
        }

        #expect(folder.contents() == ids.suffix(1000).map { "\($0).json" })
    }

    @Test("LOG-04 clear deletes every kept request")
    func clears() async throws {
        let folder = try TemporaryFolder()
        let capture = RequestCapture(folder: folder.url.appending(path: "requests"))
        _ = await capture.save(Self.record())

        await capture.clear()

        #expect(folder.contents().isEmpty)
        #expect(await capture.totalBytes() == 0)
    }

    // MARK: - Helpers

    /// The size of the record's file.
    private static func fileSize(of record: RequestRecord) async throws -> Int {
        let folder = try TemporaryFolder()
        let id = try #require(await RequestCapture(folder: folder.url).save(record))
        return LogFiles.size(of: folder.file("\(id).json"))
    }

    private static func record(body: Int = 10) -> RequestRecord {
        RequestRecord(method: "GET", url: URL(string: "https://jenkins.example.com/api/json")!, status: 200, seconds: 0.1,
                      responseBody: Data(repeating: UInt8(ascii: "b"), count: body))
    }

    /// A time that moves on by a second at each call, so the ids sort in the order of the saves.
    private static func ticking(from start: Int = 0) -> @Sendable () -> Date {
        let calls = Calls(start)
        return { Date(timeIntervalSince1970: 1_793_188_800 + Double(calls.next())) }
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count: Int

        init(_ start: Int) {
            count = start
        }

        func next() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }
    }
}
