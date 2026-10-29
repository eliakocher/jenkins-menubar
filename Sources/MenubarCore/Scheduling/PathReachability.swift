import Foundation
import Network

/// Whether the Mac has a network path, as NWPathMonitor reports it (OD-05).
///
/// A path that needs a connection first, like a VPN on demand, counts as reachable: the check itself finds out
/// whether Jenkins answers.
public struct PathReachability: Reachability {
    public init() {}

    public func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status != .unsatisfied)
            }
            continuation.onTermination = { _ in
                monitor.cancel()
            }
            monitor.start(queue: DispatchQueue(label: "\(AppIdentity.bundleID).reachability"))
        }
    }
}
