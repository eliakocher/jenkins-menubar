import Foundation
import Testing

@testable import MenubarCore

/// The keychain through `security`, against a keychain made for each test in a temporary folder. Every call passes its
/// path, and the service is a test service, so the login keychain is never touched.
@Suite("Keychain through security")
struct SecurityCLIKeychainTests {
    private static let service = "menubar-monitor-tests"
    private static let token = "glpat-Secret_123.abc~XYZ="

    @Test("ACC-01 stores a token through security stdin")
    func storesThroughStdin() async throws {
        try await withTemporaryKeychain { keychain, runner in
            try await keychain.store(Self.token, account: TokenAccount.gitlab.rawValue)

            let store = try #require(await runner.calls.first)
            #expect(store.arguments == ["-i"])
            let line = String(decoding: try #require(store.input), as: UTF8.self)
            #expect(line.hasPrefix("add-generic-password -U -s \"\(Self.service)\" -a \"GITLAB_TOKEN\" -w \"\(Self.token)\" "))
            #expect(line.hasSuffix("\n"))
            #expect(try await keychain.find(account: TokenAccount.gitlab.rawValue) == Self.token)
        }
    }

    @Test("ACC-01 no token on a command line")
    func noTokenOnACommandLine() async throws {
        try await withTemporaryKeychain { keychain, runner in
            try await keychain.store(Self.token, account: TokenAccount.gitlab.rawValue)
            _ = try await keychain.find(account: TokenAccount.gitlab.rawValue)
            try await keychain.delete(account: TokenAccount.gitlab.rawValue)

            let calls = await runner.calls
            #expect(calls.count >= 3)
            for call in calls {
                #expect(!call.arguments.contains { $0.contains(Self.token) }, "\(call.arguments)")
            }
        }
    }

    @Test("ACC-01 reads the token from the keychain")
    func readsTheToken() async throws {
        try await withTemporaryKeychain { keychain, _ in
            #expect(try await keychain.find(account: TokenAccount.jenkins.rawValue) == nil)

            try await keychain.store("first", account: TokenAccount.jenkins.rawValue)
            try await keychain.store(Self.token, account: TokenAccount.jenkins.rawValue)

            let again = SecurityCLIKeychain(service: Self.service, keychainPath: keychain.keychainPath)
            #expect(try await again.find(account: TokenAccount.jenkins.rawValue) == Self.token)
            #expect(try await again.find(account: TokenAccount.gitlab.rawValue) == nil)
        }
    }

    /// `security -i` has its own quoting: these values come back exactly as stored.
    @Test("ACC-01 keeps quotes, spaces and backslashes through security stdin", arguments: [
        #"a "quoted" value"#,
        #"back\slash and \\ two"#,
        #"ends with a backslash\"#,
        #"\""#,
        "it's $HOME and `ls`",
        "  spaces around  ",
        #"#!;|&<>(){}[]*?~"#,
    ])
    func keepsHardValues(value: String) async throws {
        try await withTemporaryKeychain { keychain, _ in
            try await keychain.store(value, account: "hard")
            #expect(try await keychain.find(account: "hard") == value)
        }
    }

    @Test("ACC-01 refuses a value that security -i would cut or misread", arguments: [
        "line\nbreak",
        "carriage\rreturn",
        "nul\0byte",
        "tab\there",
        "caf\u{E9}",
        String(repeating: "x", count: 3000),
    ])
    func refusesUnsafeValues(value: String) async throws {
        let runner = ScriptedRunner { _ in ProcessOutput(status: 0) }
        let keychain = SecurityCLIKeychain(service: Self.service, keychainPath: "/nowhere/test.keychain-db", runner: runner)

        await #expect(throws: KeychainError.unsupportedValue) {
            try await keychain.store(value, account: "unsafe")
        }
        #expect(await runner.calls.isEmpty)
    }

    @Test("ACC-01 reports a keychain that did not take the token")
    func reportsAKeychainThatDidNotTakeIt() async throws {
        // security -i ends well, but the item isn't there afterwards.
        let runner = ScriptedRunner { arguments in
            arguments == ["-i"] ? ProcessOutput(status: 0) : ProcessOutput(status: 44)
        }
        let keychain = SecurityCLIKeychain(service: Self.service, keychainPath: "/nowhere/test.keychain-db", runner: runner)

        let error = await #expect(throws: KeychainError.notStored) {
            try await keychain.store(Self.token, account: TokenAccount.gitlab.rawValue)
        }
        #expect(error?.localizedDescription == "The keychain did not take the token")
    }

    @Test("ACC-01 reports an old value left in place as not stored")
    func reportsAnOldValue() async throws {
        let runner = ScriptedRunner { arguments in
            arguments == ["-i"] ? ProcessOutput(status: 0) : ProcessOutput(status: 0, standardOutput: Data("old\n".utf8))
        }
        let keychain = SecurityCLIKeychain(service: Self.service, keychainPath: "/nowhere/test.keychain-db", runner: runner)

        await #expect(throws: KeychainError.notStored) {
            try await keychain.store(Self.token, account: TokenAccount.gitlab.rawValue)
        }
    }

    @Test("ACC-06 removes a token")
    func removesAToken() async throws {
        try await withTemporaryKeychain { keychain, _ in
            try await keychain.store(Self.token, account: TokenAccount.gitlab.rawValue)
            try await keychain.store(Self.token, account: TokenAccount.jenkins.rawValue)

            try await keychain.delete(account: TokenAccount.gitlab.rawValue)

            #expect(try await keychain.find(account: TokenAccount.gitlab.rawValue) == nil)
            #expect(try await keychain.find(account: TokenAccount.jenkins.rawValue) == Self.token)
            // Removing what isn't there is fine.
            try await keychain.delete(account: TokenAccount.gitlab.rawValue)
        }
    }

    @Test("ACC-01 quotes for security -i escape backslashes and double quotes only")
    func quoting() {
        #expect(SecurityCLIKeychain.quoted(#"a"b\c'd$e"#) == #""a\"b\\c'd$e""#)
    }

    // MARK: - Helpers

    /// Records every command line, then runs it for real.
    private actor RecordingRunner: ProcessRunner {
        private(set) var calls: [(arguments: [String], input: Data?)] = []

        func run(_ executable: URL, arguments: [String], input: Data?) async throws -> ProcessOutput {
            calls.append((arguments, input))
            return try await SystemProcessRunner().run(executable, arguments: arguments, input: input)
        }
    }

    /// Answers every command with what the script returns, without running anything.
    private actor ScriptedRunner: ProcessRunner {
        private(set) var calls: [[String]] = []
        private let script: @Sendable ([String]) -> ProcessOutput

        init(_ script: @escaping @Sendable ([String]) -> ProcessOutput) {
            self.script = script
        }

        func run(_ executable: URL, arguments: [String], input: Data?) -> ProcessOutput {
            calls.append(arguments)
            return script(arguments)
        }
    }

    /// Runs the body with a keychain made for it with `security create-keychain -p`, and deletes that keychain
    /// afterwards, whatever happened.
    private func withTemporaryKeychain(_ body: (SecurityCLIKeychain, RecordingRunner) async throws -> Void) async throws {
        let folder = try TemporaryFolder()
        let path = folder.file("test.keychain-db").path
        let security = URL(filePath: "/usr/bin/security")
        let created = try await SystemProcessRunner().run(security, arguments: ["create-keychain", "-p", "test", path], input: nil)
        try #require(created.status == 0, "security create-keychain: \(String(decoding: created.standardError, as: UTF8.self))")

        let runner = RecordingRunner()
        let result: Result<Void, any Error>
        do {
            try await body(SecurityCLIKeychain(service: Self.service, keychainPath: path, runner: runner), runner)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        _ = try? await SystemProcessRunner().run(security, arguments: ["delete-keychain", path], input: nil)
        try result.get()
    }
}
