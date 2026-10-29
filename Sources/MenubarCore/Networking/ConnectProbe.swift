import Foundation
import Network

/// What `ConnectProbe` found.
public enum ProbeResult: Sendable, Hashable {
    /// the host took the TCP connection
    case connected
    /// nothing answered within the time limit, as when the VPN is down
    case timedOut
    /// the host name doesn't resolve
    case unknownHost
    /// the host refused or reset the connection, or there is no network
    case cannotConnect
    /// any other failure, with its description
    case failed(String)
}

/// Checks that a host takes a TCP connection within a time limit, which URLSession has no setting for (NET-01).
///
/// The limit is the probe's own timer on the injected clock, not the TCP connect timeout, which would allow only whole
/// seconds and couldn't be tested. Task 1.4 in `docs/decisions.md` has what macOS does in each case.
public struct ConnectProbe: Sendable {
    private let clock: any Clock<Duration>
    private static let queue = DispatchQueue(label: "menubar-monitor.connect-probe")

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Opens a TCP connection to the host and closes it again at once.
    ///
    /// Returns `.failed` when the calling task is cancelled, without waiting for the connection.
    ///
    /// - Parameters:
    ///   - host: a host name or an IP address
    ///   - port: the TCP port
    ///   - timeout: how long the host may take to accept the connection
    /// - Returns: whether the host took the connection, or why not
    public func check(host: String, port: Int, timeout: Duration) async -> ProbeResult {
        guard let port = UInt16(exactly: port).flatMap(NWEndpoint.Port.init(rawValue:)) else {
            return .failed("invalid port \(port)")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let clock = clock
        return await withTaskGroup(of: ProbeResult?.self) { group in
            group.addTask {
                await Self.connect(connection)
            }
            group.addTask {
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    return nil
                }
                return .timedOut
            }
            defer {
                connection.cancel()
                group.cancelAll()
            }
            for await result in group {
                if let result {
                    return result
                }
            }
            return .failed(CancellationError().localizedDescription)
        }
    }

    /// Starts the connection and waits for its first final state: nil when it was cancelled.
    private static func connect(_ connection: NWConnection) async -> ProbeResult? {
        let outcome = Outcome()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                outcome.wait(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        outcome.finish(.connected)
                    // An unknown host and a refused connection end in waiting, not failed: the connection would retry
                    // when the network changes, which a probe doesn't want.
                    case .waiting(let error), .failed(let error):
                        outcome.finish(result(for: error))
                    case .cancelled:
                        outcome.finish(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            outcome.finish(nil)
        }
    }

    private static func result(for error: NWError) -> ProbeResult {
        switch error {
        case .dns:
            .unknownHost
        case .posix:
            .cannotConnect
        default:
            .failed(error.localizedDescription)
        }
    }

    /// Resumes the continuation once, with the first result, whether that comes before or after the continuation.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ProbeResult?, Never>?
        private var result: ProbeResult??

        func wait(_ continuation: CheckedContinuation<ProbeResult?, Never>) {
            let result: ProbeResult?? = lock.withLock {
                if self.result == nil {
                    self.continuation = continuation
                }
                return self.result
            }
            if let result {
                continuation.resume(returning: result)
            }
        }

        func finish(_ result: ProbeResult?) {
            let continuation: CheckedContinuation<ProbeResult?, Never>? = lock.withLock {
                guard self.result == nil else {
                    return nil
                }
                self.result = .some(result)
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: result)
        }
    }
}
