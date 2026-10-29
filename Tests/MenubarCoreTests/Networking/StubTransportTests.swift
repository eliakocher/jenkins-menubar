import Foundation
import Testing

@testable import MenubarCore

@Suite("StubTransport")
struct StubTransportTests {
    private let jobs = URL(string: "https://jenkins.example.com/job/project/api/json?tree=jobs%5Bname%5D")!
    private let graphQL = URL(string: "https://gitlab.example.com/api/graphql")!

    @Test("StubTransport answers after its delay on the test clock and keeps the requests")
    func answersAfterDelay() async throws {
        let clock = TestClock()
        let stub = StubTransport(clock: clock)
        stub.answer("GET", path: "/job/project/api/json", after: .seconds(2), body: #"{"jobs":[]}"#)

        let send = Task { try await stub.send(HTTPRequest(url: jobs, timeout: .seconds(60))) }
        await clock.waitForSleepers()
        #expect(stub.requests(path: "/job/project/api/json").count == 1)
        clock.advance(by: .seconds(2))

        let response = try await send.value
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"jobs":[]}"#)
        #expect(stub.requests.map(\.url) == [jobs])
    }

    @Test("StubTransport ends a delay longer than the time limit with no answer")
    func delayPastTheLimit() async throws {
        let clock = TestClock()
        let stub = StubTransport(clock: clock)
        stub.answer(path: "/job/project/api/json", after: .seconds(61))

        let send = Task { try await stub.send(HTTPRequest(url: jobs, timeout: .seconds(60))) }
        await clock.waitForSleepers()
        clock.advance(by: .seconds(60))

        await #expect(throws: TransportError.noAnswer(within: .seconds(60))) { try await send.value }
    }

    @Test("StubTransport prefers the newest route and counts its times")
    func newestRouteFirst() async throws {
        let stub = StubTransport(clock: TestClock())
        stub.answer(operation: "WorkItems", body: "later")
        stub.fail(operation: "WorkItems", times: 1, with: .unknownHost)
        stub.answer(operation: "MergeRequests", status: 401)
        let request = HTTPRequest(
            method: "POST",
            url: graphQL,
            timeout: .seconds(30),
            graphQL: GraphQLOperation(name: "WorkItems", variables: #"{"first":20}"#)
        )

        await #expect(throws: TransportError.unknownHost) { try await stub.send(request) }
        #expect(String(decoding: try await stub.send(request).body, as: UTF8.self) == "later")
        #expect(stub.requests(operation: "WorkItems").count == 2)
        #expect(stub.requests(operation: "MergeRequests").isEmpty)
    }

    @Test("StubTransport names a request that no route takes")
    func noRoute() async throws {
        let stub = StubTransport(clock: TestClock())
        stub.answer("POST", path: "/job/project/api/json")

        let error = await #expect(throws: TransportError.self) {
            try await stub.send(HTTPRequest(url: jobs, timeout: .seconds(20)))
        }
        #expect(error?.message == "StubTransport has no route for GET \(jobs.absoluteString)")
        #expect(stub.requests.count == 1)
    }
}
