import Foundation
import Testing

@testable import MenubarCore

@Suite("TokenStore")
struct TokenStoreTests {
    @Test("ACC-03 refuses a token with spaces", arguments: ["glpat abc", "glpat\tabc", "a\nb"])
    func refusesSpaces(token: String) async throws {
        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain)

        let error = await #expect(throws: TokenError.invalidFormat) {
            try await store.store(token, for: .gitlab)
        }
        #expect(error?.localizedDescription == "That does not look like a token: it has spaces or quotes")
        #expect(await keychain.values.isEmpty)
    }

    @Test("ACC-03 refuses a token with quotes", arguments: [#"glpat"abc"#, "glpat'abc", #"back\slash"#, "", "caf\u{E9}"])
    func refusesQuotes(token: String) async throws {
        let keychain = InMemoryKeychain()

        await #expect(throws: TokenError.invalidFormat) {
            try await TokenStore(keychain: keychain).store(token, for: .jenkins)
        }
        #expect(await keychain.values.isEmpty)
    }

    @Test("ACC-03 takes base64 and the characters of tokens, without the spaces around them")
    func takesValidTokens() async throws {
        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain)

        try await store.store(" glpat-AZaz09_.~-+/= \n", for: .gitlab)

        #expect(try await store.token(.gitlab) == "glpat-AZaz09_.~-+/=")
        #expect(await keychain.values == ["GITLAB_TOKEN": "glpat-AZaz09_.~-+/="])
    }

    @Test("ACC-06 saves the Jenkins token as base64 of user and token")
    func jenkinsTokenIsBase64() async throws {
        let token = TokenStore.jenkinsToken(user: " jdoe ", apiToken: "11aa22bb\n")
        #expect(token == Data("jdoe:11aa22bb".utf8).base64EncodedString())

        let keychain = InMemoryKeychain()
        try await TokenStore(keychain: keychain).store(token, for: .jenkins)
        #expect(await keychain.values["JENKINS_MCP_BASIC_AUTH"] == token)
    }

    @Test("ACC-06 prefills the Jenkins user from the token")
    func jenkinsUserFromToken() {
        #expect(TokenStore.jenkinsUser(fromToken: TokenStore.jenkinsToken(user: "jdoe", apiToken: "a:b")) == "jdoe")
        #expect(TokenStore.jenkinsUser(fromToken: "not base64!") == nil)
        #expect(TokenStore.jenkinsUser(fromToken: Data("no colon".utf8).base64EncodedString()) == nil)
    }

    @Test("ACC-06 logs saving and removing")
    func logsSavingAndRemoving() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let store = TokenStore(keychain: InMemoryKeychain(), log: log)

        try await store.store("glpat-secret", for: .gitlab)
        try await store.remove(.jenkins)

        let entries = await log.entries()
        #expect(entries.map(\.message) == ["Saved the GitLab token in the keychain", "Removed the Jenkins token from the keychain"])
        #expect(entries.allSatisfy { $0.level == .info && $0.source == .settings })
        #expect(try !folder.read("menubar-monitor.log").contains("glpat-secret"))
    }

    @Test("ACC-06 a token the keychain didn't take is not logged as saved")
    func failedSaveIsNotLogged() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let keychain = InMemoryKeychain()
        await keychain.failStoring(with: .notStored)

        await #expect(throws: KeychainError.notStored) {
            try await TokenStore(keychain: keychain, log: log).store("glpat-secret", for: .gitlab)
        }
        #expect(await log.entries().isEmpty)
    }

    @Test("ACC-01 the accounts keep the names of jenkins-menubar")
    func accountNames() {
        #expect(TokenAccount.allCases.map(\.rawValue) == ["JENKINS_MCP_BASIC_AUTH", "GITLAB_TOKEN"])
        #expect(SecurityCLIKeychain().service == "menubar-monitor")
    }
}
