import Foundation

/// The tokens the app keeps, by their keychain account. The names are the ones jenkins-menubar used, so the import
/// and anyone's own scripts find them.
public enum TokenAccount: String, Sendable, Hashable, CaseIterable, Codable {
    /// base64 of `user:api-token`, sent to Jenkins as Basic auth
    case jenkins = "JENKINS_MCP_BASIC_AUTH"
    /// a GitLab token with the `api` scope (`read_api` reads, and cannot re-request a review), sent as Bearer auth
    case gitlab = "GITLAB_TOKEN"

    /// "Jenkins" or "GitLab"
    public var displayName: String {
        switch self {
        case .jenkins: "Jenkins"
        case .gitlab: "GitLab"
        }
    }
}

public enum TokenError: Error, Sendable, Hashable {
    /// the token doesn't match `TokenStore.pattern` (ACC-03)
    case invalidFormat
}

extension TokenError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidFormat: "That does not look like a token: it has spaces or quotes"
        }
    }
}

/// Reads, stores and removes the tokens in a keychain, and logs the changes without the tokens (ACC-01, ACC-03, ACC-06).
public struct TokenStore: Sendable {
    public let keychain: any Keychain
    private let log: ActivityLog?

    public init(keychain: any Keychain, log: ActivityLog? = nil) {
        self.keychain = keychain
        self.log = log
    }

    /// The stored token, or nil when there is none.
    public func token(_ account: TokenAccount) async throws -> String? {
        try await keychain.find(account: account.rawValue)
    }

    /// Stores the token, without the spaces and line breaks around it, after checking its format.
    ///
    /// Throws `TokenError.invalidFormat` without touching the keychain, or `KeychainError.notStored` when the keychain
    /// didn't take it.
    public func store(_ token: String, for account: TokenAccount) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(token) else {
            throw TokenError.invalidFormat
        }
        try await keychain.store(token, account: account.rawValue)
        await log?.log(.info, .settings, "Saved the \(account.displayName) token in the keychain")
    }

    /// Removes the token from the keychain.
    public func remove(_ account: TokenAccount) async throws {
        try await keychain.delete(account: account.rawValue)
        await log?.log(.info, .settings, "Removed the \(account.displayName) token from the keychain")
    }

    /// Whether the token matches `^[A-Za-z0-9+/=._~-]+$`, the rule of jenkins-menubar: base64, and the characters of
    /// GitLab and Jenkins tokens.
    public static func isValid(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+/=._~-".unicodeScalars.contains($0))
        }
    }

    /// The Jenkins token to store: base64 of `user:api-token`, both trimmed (ACC-06).
    public static func jenkinsToken(user: String, apiToken: String) -> String {
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return Data("\(user):\(apiToken)".utf8).base64EncodedString()
    }

    /// The Jenkins user a stored token belongs to, the part before the first `:`; nil when it isn't base64 of
    /// `user:api-token`.
    public static func jenkinsUser(fromToken token: String) -> String? {
        guard let data = Data(base64Encoded: token), let decoded = String(data: data, encoding: .utf8),
              let colon = decoded.firstIndex(of: ":") else {
            return nil
        }
        return String(decoded[..<colon])
    }
}
