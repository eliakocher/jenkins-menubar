import Foundation

/// A token found outside menubar-monitor's keychain, and where it was found (ACC-02).
///
/// Its description and its mirror name only the source, so a token never reaches a log or a test's output by accident.
public struct LegacyToken: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Where a token comes from, in the order they are looked at.
    public enum Source: String, Codable, Hashable, Sendable, CaseIterable {
        /// the keychain service `jenkins-menubar`
        case oldKeychain
        /// the app's environment
        case environment
        /// a plain `export NAME=value` in `~/.zshrc`
        case zshrc
        /// an export in `~/.zshrc` whose value zsh would have to compute, like `$(security …)`
        case zshrcComputed
        case missing

        /// where the token comes from, as Settings and the welcome flow say it
        public var displayName: String {
            switch self {
            case .oldKeychain: "keychain (jenkins-menubar)"
            case .environment: "environment"
            case .zshrc: "~/.zshrc"
            case .zshrcComputed: "computed in ~/.zshrc"
            case .missing: "missing"
            }
        }
    }

    public var source: Source
    /// the token; nil for ``Source/zshrcComputed`` and ``Source/missing``
    public var value: String?

    public init(source: Source, value: String? = nil) {
        self.source = source
        self.value = value
    }

    public var description: String { "LegacyToken(\(source.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["source": source]) }
}

/// Looks for the tokens jenkins-menubar used: in its keychain service, in the app's environment, and in a plain export
/// in `~/.zshrc` (ACC-02).
public struct LegacyTokenFinder: Sendable {
    /// jenkins-menubar's keychain service
    public static let oldKeychainService = "jenkins-menubar"

    private let oldKeychain: any Keychain
    private let environment: [String: String]
    private let zshrc: URL?

    /// Creates a finder. Nothing is read yet.
    ///
    /// - Parameters:
    ///   - oldKeychain: jenkins-menubar's keychain service, like `SecurityCLIKeychain(service: "jenkins-menubar")`
    ///   - environment: the app's environment
    ///   - zshrc: `~/.zshrc`; nil to skip it
    public init(oldKeychain: any Keychain, environment: [String: String], zshrc: URL?) {
        self.oldKeychain = oldKeychain
        self.environment = environment
        self.zshrc = zshrc
    }

    /// Returns the finder for the user's own keychain, environment and `~/.zshrc`.
    ///
    /// - Parameters:
    ///   - home: the user's home folder
    ///   - environment: the app's environment
    /// - Returns: the finder
    public static func standard(
        home: URL = URL.homeDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LegacyTokenFinder {
        LegacyTokenFinder(
            oldKeychain: SecurityCLIKeychain(service: oldKeychainService), environment: environment,
            zshrc: home.appending(path: ".zshrc", directoryHint: .notDirectory))
    }

    /// Looks for a token: in the old keychain service, then the environment, then `~/.zshrc`.
    ///
    /// The old tool read the environment first. Here the old keychain comes first (ACC-02): an app opened from Finder
    /// has no shell environment anyway. A keychain that can't be read counts as not holding the token.
    ///
    /// - Parameter account: the token's account, which is also its variable name
    /// - Returns: the token and where it was found
    public func find(_ account: TokenAccount) async -> LegacyToken {
        let name = account.rawValue
        if let value = try? await oldKeychain.find(account: name), !value.isEmpty {
            return LegacyToken(source: .oldKeychain, value: value)
        }
        if let value = environment[name], !value.isEmpty {
            return LegacyToken(source: .environment, value: value)
        }
        let text = zshrc.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        switch ZshrcExport.find(name, in: text) {
        case .plain(let value): return LegacyToken(source: .zshrc, value: value)
        case .computed: return LegacyToken(source: .zshrcComputed)
        case .none: return LegacyToken(source: .missing)
        }
    }
}

/// The value of the last `export NAME=value` line in `~/.zshrc`, read as jenkins-menubar's `exported()` read it.
enum ZshrcExport: Hashable, Sendable {
    case none
    case plain(String)
    /// a value with `$` or a backtick, which only zsh could compute
    case computed

    /// Finds the variable's export.
    ///
    /// The last line that is `export NAME=` after optional blanks counts, as the last assignment wins in zsh. Its value
    /// is single-quoted (taken as written), double-quoted or bare (up to the first blank, so a comment after it is
    /// left out). An empty value counts as no export.
    ///
    /// - Parameters:
    ///   - name: the variable, like `GITLAB_TOKEN`
    ///   - text: the contents of `~/.zshrc`
    /// - Returns: the export
    static func find(_ name: String, in text: String) -> ZshrcExport {
        let prefix = "export \(name)="
        guard let line = text.split(whereSeparator: \.isNewline)
            .map({ $0.drop(while: \.isWhitespace) })
            .last(where: { $0.hasPrefix(prefix) })
        else { return .none }

        let rest = line.dropFirst(prefix.count)
        let value: Substring
        switch rest.first {
        case "'":
            // Nothing inside single quotes is expanded.
            let quoted = rest.dropFirst().prefix { $0 != "'" }
            return quoted.isEmpty ? .none : .plain(String(quoted))
        case "\"":
            value = rest.dropFirst().prefix { $0 != "\"" }
        default:
            value = rest.prefix { !$0.isWhitespace }
        }
        if value.contains("$") || value.contains("`") {
            return .computed
        }
        return value.isEmpty ? .none : .plain(String(value))
    }
}
