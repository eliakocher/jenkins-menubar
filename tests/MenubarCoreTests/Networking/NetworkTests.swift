import Foundation
import Testing

@testable import MenubarCore

/// `URLSessionTransport` and `ConnectProbe` against sockets on this Mac: no outside network, no real server.
@Suite("Network")
struct NetworkTests {
    @Test("NET-01 no connection within 5 seconds")
    func noConnection() async throws {
        let clock = TestClock()
        let transport = URLSessionTransport(clock: clock)
        let url = try #require(URL(string: "http://\(try Self.unansweredHost()):9/job/project/api/json"))

        let send = Task { try await transport.send(HTTPRequest(url: url, timeout: .seconds(20))) }
        await clock.waitForSleepers()
        clock.advance(by: .milliseconds(4900))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .milliseconds(100))

        let error = await #expect(throws: TransportError.noConnection(within: .seconds(5))) { try await send.value }
        #expect(error?.message == "no connection within 5 seconds (VPN?)")
        #expect(error?.outcomeLabel == "TIMEOUT")
    }

    @Test("NET-01 no answer within the total time")
    func noAnswer() async throws {
        let server = try LocalServer(answer: nil)
        let clock = TestClock()
        let transport = URLSessionTransport(clock: clock)

        let send = Task { try await transport.send(HTTPRequest(url: server.url("/job/project/api/json"), timeout: .seconds(20))) }
        try await server.waitForRequests(1)
        await clock.waitForSleepers()
        clock.advance(by: .seconds(20))

        let error = await #expect(throws: TransportError.noAnswer(within: .seconds(20))) { try await send.value }
        #expect(error?.message == "no answer within 20 seconds")
        #expect(error?.outcomeLabel == "TIMEOUT")
        // Past the probe, the task's metrics decide; without metrics the probe's connection counts.
        #expect(TransportError(DeadlinePassed(), connected: false, limit: .seconds(30)) == .noConnection(within: .seconds(30)))
        #expect(TransportError(DeadlinePassed(), connected: true, limit: .seconds(30)) == .noAnswer(within: .seconds(30)))
        #expect(TransportError(DeadlinePassed(), connected: nil, limit: .seconds(30)) == .noAnswer(within: .seconds(30)))
        #expect(TransportError.noAnswer(within: .seconds(1)).message == "no answer within 1 second")
        #expect(TransportError.noAnswer(within: .milliseconds(250)).message == "no answer within 0.25 seconds")
    }

    @Test("NET-01 unknown host and refused connection are offline")
    func offline() async throws {
        let transport = URLSessionTransport()
        let closedPort = try Listener(backlog: 1).port

        // RFC 6761 reserves .invalid: it never resolves.
        let unknown = await #expect(throws: TransportError.unknownHost) {
            try await transport.send(HTTPRequest(url: URL(string: "https://jenkins.invalid/api/json")!, timeout: .seconds(20)))
        }
        let refused = await #expect(throws: TransportError.cannotConnect) {
            try await transport.send(HTTPRequest(url: URL(string: "http://127.0.0.1:\(closedPort)/api/json")!, timeout: .seconds(20)))
        }

        #expect(unknown?.message == "unknown host (VPN?)")
        #expect(refused?.message == "no connection (VPN?)")
        #expect(unknown?.outcomeLabel == "OFFLINE")
        #expect(refused?.outcomeLabel == "OFFLINE")
        // The same when URLSession finds out, after the probe was skipped.
        #expect(TransportError(URLError(.cannotFindHost), connected: nil, limit: .seconds(20)) == .unknownHost)
        #expect(TransportError(URLError(.cannotConnectToHost), connected: nil, limit: .seconds(20)) == .cannotConnect)
        #expect(TransportError(URLError(.notConnectedToInternet), connected: nil, limit: .seconds(20)) == .cannotConnect)
        #expect(TransportError(URLError(.secureConnectionFailed), connected: true, limit: .seconds(20)).outcomeLabel == "ERROR")
    }

    @Test("NET-01 timeouts per request kind")
    func timeoutsPerKind() {
        let timeouts = Timeouts.standard

        #expect(timeouts.connect == .seconds(5))
        #expect(timeouts.jenkinsJobList == .seconds(60))
        #expect(timeouts.jenkins == .seconds(20))
        #expect(timeouts.gitLab == .seconds(30))
    }

    /// Task 1.4. macOS doesn't drop the connection a full accept queue has no room for, as Linux does: it completes the
    /// handshake and resets the connection right after. A SYN that goes unanswered, as when the VPN is down, is what
    /// the probe's limit is for, and another 127 address gives one without any network.
    @Test("NET-01 connect probe answers within a second", arguments: ProbeTarget.allCases)
    func probeWithinASecond(target: ProbeTarget) async throws {
        let probe = ConnectProbe()
        let clock = ContinuousClock()
        let limit = Duration.milliseconds(300)

        switch target {
        case .fullAcceptQueue:
            let listener = try Listener(backlog: 1)
            let queued = try Listener.connect(to: listener.port)
            defer { close(queued) }
            let overflow = try Listener.connect(to: listener.port, expecting: ECONNRESET)
            #expect(overflow == -1, "the accept queue should be full")

            let start = clock.now
            let result = await probe.check(host: "127.0.0.1", port: listener.port, timeout: limit)
            #expect(result != .timedOut)
            #expect(start.duration(to: clock.now) < limit)
        case .unansweredConnect:
            let start = clock.now
            let result = await probe.check(host: try Self.unansweredHost(), port: 9, timeout: limit)
            let elapsed = start.duration(to: clock.now)
            #expect(result == .timedOut)
            #expect(elapsed >= limit)
            #expect(elapsed < .seconds(1))
        }
    }

    @Test("NET-01 the connect probe runs once per host per check")
    func probeOncePerCheck() async throws {
        let server = try LocalServer(answer: LocalServer.ok)
        let clock = TestClock()
        let transport = URLSessionTransport(probeReuse: .seconds(10), clock: clock)
        let request = HTTPRequest(url: server.url("/api/json"), timeout: .seconds(20))

        // A probe's connection comes before its request's, and connections are accepted in order: once an answer is
        // back, the server has counted the probe.
        _ = try await transport.send(request)
        #expect(server.connections == 2)
        _ = try await transport.send(request)
        #expect(server.connections == 3)
        clock.advance(by: .seconds(10))
        _ = try await transport.send(request)
        #expect(server.connections == 5)
    }

    @Test("a cancelled send throws CancellationError, not a timeout")
    func cancelledSend() async throws {
        let clock = TestClock()
        let transport = URLSessionTransport(clock: clock)
        let url = try #require(URL(string: "http://\(try Self.unansweredHost()):9/"))

        let send = Task { try await transport.send(HTTPRequest(url: url, timeout: .seconds(20))) }
        await clock.waitForSleepers()
        send.cancel()

        await #expect(throws: CancellationError.self) { try await send.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test("NET-02 cookies are not stored")
    func noCookies() async throws {
        let server = try LocalServer(answer: LocalServer.ok)
        let transport = URLSessionTransport()
        let request = HTTPRequest(url: server.url("/api/json"), headers: ["Authorization": "Basic dXNlcjp0b2tlbg=="], timeout: .seconds(5))

        let first = try await transport.send(request)
        let second = try await transport.send(request)

        #expect(first.status == 200)
        #expect(String(decoding: second.body, as: UTF8.self) == "{}")
        // The answer keeps Set-Cookie, for RequestRecorder to drop; the session neither keeps nor sends it back.
        #expect(first.header("set-cookie") == "JSESSIONID=abc123; Path=/")
        let heads = server.requests
        #expect(heads.count == 2)
        #expect(heads.allSatisfy { !$0.lowercased().contains("\r\ncookie:") })
        #expect(HTTPCookieStorage.shared.cookies(for: server.url("/"))?.isEmpty ?? true)
        // The token goes as given, although Apple's documentation reserves the Authorization header for URLSession.
        #expect(heads.allSatisfy { $0.contains("\r\nAuthorization: Basic dXNlcjp0b2tlbg==\r\n") })
    }

    enum ProbeTarget: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case fullAcceptQueue = "a full accept queue"
        case unansweredConnect = "an unanswered connect"

        var testDescription: String { rawValue }
    }

    /// An address on this Mac that drops a SYN without an answer.
    ///
    /// 127/8 is routed to lo0, but only 127.0.0.1 is configured there by default; a SYN to another 127 address loops
    /// back and is dropped. A Mac with lo0 aliases skips the ones in use.
    static func unansweredHost() throws -> String {
        var configured: Set<String> = []
        var addresses: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addresses) == 0 {
            var next = addresses
            while let current = next {
                if let address = current.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    configured.insert(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                }
                next = current.pointee.ifa_next
            }
            freeifaddrs(addresses)
        }
        return try #require((2...9).map { "127.0.0.\($0)" }.first { !configured.contains($0) })
    }
}

/// A listening TCP socket on 127.0.0.1, on a port of its own, closed when the value goes away.
private final class Listener: Sendable {
    let descriptor: Int32
    let port: Int

    init(backlog: Int32) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = Listener.loopback(port: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length) == 0 && listen(descriptor, backlog) == 0 && getsockname(descriptor, $0, &length) == 0
            }
        }
        guard listening else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            throw error
        }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit {
        close(descriptor)
    }

    /// Connects a blocking socket to a port on 127.0.0.1.
    ///
    /// - Parameters:
    ///   - port: the port
    ///   - expected: an errno the connection may fail with
    /// - Returns: the connected socket, which the caller closes, or -1 when it failed with `expected`
    static func connect(to port: Int, expecting expected: Int32? = nil) throws -> Int32 {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        var address = loopback(port: UInt16(port))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        if connected {
            return client
        }
        let failure = errno
        close(client)
        if failure == expected {
            return -1
        }
        throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        return address
    }
}

/// A small HTTP server on 127.0.0.1 that answers every request the same way, or never. It stops when the value goes
/// away.
private final class LocalServer: Sendable {
    /// an answer that sets a cookie and closes the connection
    static let ok = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Set-Cookie: JSESSIONID=abc123; Path=/\r
        Content-Length: 2\r
        Connection: close\r
        \r
        {}
        """

    private let core: ServerCore

    /// Starts the server.
    ///
    /// - Parameter answer: the raw HTTP answer to every request; nil to read the requests and never answer
    init(answer: String?) throws {
        let core = try ServerCore(answer: answer)
        self.core = core
        Thread.detachNewThread {
            core.serve()
        }
    }

    deinit {
        core.stop()
    }

    /// the heads of the requests that came, oldest first; a connection without a request, like the probe's, adds none
    var requests: [String] {
        core.lock.withLock { core.heads }
    }

    /// the number of connections accepted
    var connections: Int {
        core.lock.withLock { core.accepted }
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(core.listener.port)\(path)")!
    }

    /// Waits until `count` requests came, for at most 5 seconds.
    ///
    /// - Parameter count: the number of requests
    func waitForRequests(_ count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while requests.count < count {
            try #require(clock.now < deadline, "\(requests.count) of \(count) requests came")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// The server's state, owned by its threads, so the listening socket is closed only after the accepting thread is done
/// with it.
private final class ServerCore: @unchecked Sendable {
    let listener: Listener
    let answer: String?
    let lock = NSLock()
    var heads: [String] = []
    var accepted = 0
    private var held: [Int32] = []
    private var stopped = false

    init(answer: String?) throws {
        listener = try Listener(backlog: 16)
        self.answer = answer
    }

    func stop() {
        lock.withLock {
            stopped = true
            for connection in held {
                shutdown(connection, SHUT_RDWR)
                close(connection)
            }
            held = []
        }
    }

    /// Accepts connections until the server stops; the poll's short timeout lets the thread notice that.
    func serve() {
        var listening = pollfd(fd: listener.descriptor, events: Int16(POLLIN), revents: 0)
        while !lock.withLock({ stopped }) {
            guard poll(&listening, 1, 50) > 0 else {
                continue
            }
            let connection = accept(listener.descriptor, nil, nil)
            guard connection >= 0 else {
                continue
            }
            lock.withLock { accepted += 1 }
            Thread.detachNewThread {
                self.handle(connection)
            }
        }
    }

    private func handle(_ connection: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while received.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else {
                close(connection)
                return
            }
            received.append(contentsOf: buffer[..<count])
        }
        let head = String(decoding: received, as: UTF8.self)
        guard let answer else {
            let keep = lock.withLock {
                heads.append(head)
                if !stopped {
                    held.append(connection)
                }
                return !stopped
            }
            if !keep {
                close(connection)
            }
            return
        }
        lock.withLock { heads.append(head) }
        _ = answer.withCString { write(connection, $0, strlen($0)) }
        close(connection)
    }
}
