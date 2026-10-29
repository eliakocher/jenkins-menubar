#if DEBUG
import Foundation

/// A keychain in memory, for the tests and the gallery. Debug builds only.
public actor InMemoryKeychain: Keychain {
    public private(set) var values: [String: String]
    /// when set, `store` throws it, like a keychain that didn't take the value
    public var storeError: KeychainError?

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public func find(account: String) -> String? {
        values[account]
    }

    public func store(_ value: String, account: String) throws {
        if let storeError {
            throw storeError
        }
        values[account] = value
    }

    public func delete(account: String) {
        values[account] = nil
    }

    public func failStoring(with error: KeychainError?) {
        storeError = error
    }
}
#endif
