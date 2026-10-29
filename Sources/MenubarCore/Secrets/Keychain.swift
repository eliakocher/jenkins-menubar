import Foundation

/// Generic passwords of one keychain service, by account.
public protocol Keychain: Sendable {
    /// Returns the value stored for the account, or nil when there is none.
    func find(account: String) async throws -> String?
    /// Stores the value for the account, replacing any earlier one, and checks that the keychain took it.
    func store(_ value: String, account: String) async throws
    /// Removes the account's value. Removing a value that isn't there is not an error.
    func delete(account: String) async throws
}

public enum KeychainError: Error, Sendable, Hashable {
    /// the value has a character `security -i` can't take safely (only printable ASCII can), or is too long
    case unsupportedValue
    /// reading the value back after storing it gave something else, or nothing (ACC-01)
    case notStored
    /// `security` failed with another exit status; the message is its stderr, which never holds a secret
    case failed(status: Int32, message: String)
}

extension KeychainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedValue: "The keychain can't take that value: it has characters other than letters, digits and punctuation, or is too long"
        case .notStored: "The keychain did not take the token"
        case .failed(let status, let message): message.isEmpty ? "The keychain failed (security exited with \(status))" : message
        }
    }
}

/// The keychain, through `/usr/bin/security`.
///
/// The app's ad-hoc signature changes with every rebuild, so items the app wrote through the Security framework would
/// ask for access after each rebuild. Items `security` writes trust `security`, which never changes.
///
/// A value is stored by writing the `add-generic-password` command to the stdin of `security -i`, so it never shows on
/// a command line, where any process could read it. Reading and deleting don't pass a secret and run as plain commands.
public struct SecurityCLIKeychain: Keychain {
    /// the exit status of `security` when the item isn't there
    static let itemNotFound: Int32 = 44
    /// `security -i` splits a line longer than 4096 bytes and runs the rest as a command of its own; when the cut falls
    /// inside the value, the first part, which no longer names a keychain, goes to the default keychain. Verified on
    /// macOS 27.2. Half of that leaves room.
    static let maxLineBytes = 2048

    public let service: String
    /// the keychain file to use; nil uses the default keychain, the login keychain
    public let keychainPath: String?
    private let runner: any ProcessRunner
    private let security = URL(filePath: "/usr/bin/security")

    public init(service: String = AppIdentity.keychainService, keychainPath: String? = nil, runner: any ProcessRunner = SystemProcessRunner()) {
        self.service = service
        self.keychainPath = keychainPath
        self.runner = runner
    }

    public func find(account: String) async throws -> String? {
        let output = try await runner.run(security, arguments: ["find-generic-password", "-s", service, "-a", account, "-w"] + keychainArgument, input: nil)
        switch output.status {
        case 0:
            // -w prints the value and a line break; values other than printable ASCII come out as hex, which store() refuses.
            var value = String(decoding: output.standardOutput, as: UTF8.self)
            if value.hasSuffix("\n") {
                value.removeLast()
            }
            return value
        case Self.itemNotFound:
            return nil
        default:
            throw Self.failure(output)
        }
    }

    public func store(_ value: String, account: String) async throws {
        let line = try Self.storeCommand(service: service, account: account, value: value, keychainPath: keychainPath)
        // The exit status and the output of -i don't tell whether the item was written, and stderr can echo the line,
        // so they are left unread: reading the value back tells.
        _ = try await runner.run(security, arguments: ["-i"], input: Data(line.utf8))
        guard (try? await find(account: account)) == value else {
            throw KeychainError.notStored
        }
    }

    public func delete(account: String) async throws {
        let output = try await runner.run(security, arguments: ["delete-generic-password", "-s", service, "-a", account] + keychainArgument, input: nil)
        guard output.status == 0 || output.status == Self.itemNotFound else {
            throw Self.failure(output)
        }
    }

    private var keychainArgument: [String] {
        keychainPath.map { [$0] } ?? []
    }

    /// The line `security -i` reads to store the value, with a line break at its end.
    ///
    /// Throws `unsupportedValue` for anything but printable ASCII: a line break or a NUL would end the command early,
    /// and `find -w` prints other values as hex, so they wouldn't read back as stored.
    static func storeCommand(service: String, account: String, value: String, keychainPath: String?) throws -> String {
        let arguments = [service, account, value] + (keychainPath.map { [$0] } ?? [])
        guard arguments.allSatisfy(isPrintableASCII) else {
            throw KeychainError.unsupportedValue
        }
        var line = "add-generic-password -U -s \(quoted(service)) -a \(quoted(account)) -w \(quoted(value))"
        if let keychainPath {
            line += " \(quoted(keychainPath))"
        }
        line += "\n"
        guard line.utf8.count <= maxLineBytes else {
            throw KeychainError.unsupportedValue
        }
        return line
    }

    /// The argument in double quotes for the command parser of `security -i`, which takes a backslash as escaping the
    /// character after it, inside quotes too. Single quotes and `$` need no escaping there.
    static func quoted(_ argument: String) -> String {
        "\"" + argument.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func isPrintableASCII(_ string: String) -> Bool {
        string.utf8.allSatisfy { (0x20...0x7E).contains($0) }
    }

    private static func failure(_ output: ProcessOutput) -> KeychainError {
        let message = String(decoding: output.standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(status: output.status, message: message)
    }
}
