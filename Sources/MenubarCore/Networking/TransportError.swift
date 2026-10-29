import Foundation

/// Why a request got no HTTP answer, with the texts of NET-01.
public enum TransportError: Error, Sendable, Hashable {
    /// no TCP connection within the connect limit: "no connection within 5 seconds (VPN?)"
    case noConnection(within: Duration)
    /// connected, but the whole answer didn't come in time: "no answer within 20 seconds"
    case noAnswer(within: Duration)
    /// the host name doesn't resolve: "unknown host (VPN?)"
    case unknownHost
    /// the host refused the connection, or there is no network: "no connection (VPN?)"
    case cannotConnect
    /// any other failure, with its description
    case other(String)

    /// The text the log and the problem rows show.
    public var message: String {
        switch self {
        case .noConnection(let limit): "no connection within \(Self.seconds(limit)) (VPN?)"
        case .noAnswer(let limit): "no answer within \(Self.seconds(limit))"
        case .unknownHost: "unknown host (VPN?)"
        case .cannotConnect: "no connection (VPN?)"
        case .other(let description): description
        }
    }

    /// The outcome label of the log entry (LOG-01): `TIMEOUT`, `OFFLINE` or `ERROR`.
    public var outcomeLabel: String {
        switch self {
        case .noConnection, .noAnswer: "TIMEOUT"
        case .unknownHost, .cannotConnect: "OFFLINE"
        case .other: "ERROR"
        }
    }

    /// "5 seconds", "1 second", "0.25 seconds".
    private static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let number = value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
        return value == 1 ? "1 second" : "\(number) seconds"
    }
}

extension TransportError: LocalizedError {
    public var errorDescription: String? { message }
}
