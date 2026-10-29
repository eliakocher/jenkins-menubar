#if DEBUG
import Foundation

/// A login item that only records what it was asked, for the tests and the gallery. Debug builds only.
@MainActor
public final class FakeLoginItem: LoginItem {
    /// What the login item was asked to do.
    public enum Call: Hashable, Sendable {
        case register
        case unregister
        case openSystemSettings
    }

    public var status: LoginItemStatus
    /// the status `register()` leads to; ``LoginItemStatus/requiresApproval`` acts like macOS asking the user
    public var statusAfterRegister: LoginItemStatus = .enabled
    /// when set, `register()` and `unregister()` throw it and leave the status as it was
    public var error: (any Error)?
    public private(set) var calls: [Call] = []

    public init(status: LoginItemStatus = .notRegistered) {
        self.status = status
    }

    public func register() throws {
        calls.append(.register)
        if let error {
            throw error
        }
        status = statusAfterRegister
    }

    public func unregister() throws {
        calls.append(.unregister)
        if let error {
            throw error
        }
        status = .notRegistered
    }

    public func openSystemSettings() {
        calls.append(.openSystemSettings)
    }
}
#endif
