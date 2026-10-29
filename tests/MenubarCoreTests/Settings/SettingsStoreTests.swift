import Foundation
import Testing

@testable import MenubarCore

@Suite("SettingsStore")
@MainActor
struct SettingsStoreTests {
    private nonisolated static let jobURL = "https://jenkins.example.com/jenkins/job/GitLab%20Team/job/team%252Fproduct"
    private nonisolated static let jobPath = "/jenkins/job/GitLab%20Team/job/team%252Fproduct/api/json"
    private nonisolated static let team = TeamValues(
        jenkinsJobURL: jobURL, gitLabURL: "https://gitlab.example.com", gitLabProject: "team/product")
    private nonisolated static let jenkinsToken = TokenStore.jenkinsToken(user: "jdoe", apiToken: "secret-api-token")
    private nonisolated static let gitLabToken = "glpat-SecretToken_123"

    /// What the store asked the app to do.
    private actor Calls {
        var checks = 0
        var intervals: [Duration] = []

        func checkNow() {
            checks += 1
        }

        func setCheckInterval(_ interval: Duration) {
            intervals.append(interval)
        }
    }

    /// A store over a temporary folder, its own UserDefaults suite, a keychain in memory, a stub transport and a fake
    /// login item.
    @MainActor
    private struct Harness {
        let folder: TemporaryFolder
        let suite = TemporaryDefaults()
        let keychain: InMemoryKeychain
        let log: ActivityLog
        let stub: StubTransport
        let clock: TestClock
        let loginItem: FakeLoginItem
        let calls: Calls
        let teamStore: TeamStore
        let store: SettingsStore

        init(team: TeamValues = SettingsStoreTests.team, tokens: [TokenAccount: String] = [:]) throws {
            let stub = StubTransport()
            let calls = Calls()
            let clock = TestClock()
            let loginItem = FakeLoginItem()
            self.stub = stub
            self.calls = calls
            self.clock = clock
            self.loginItem = loginItem
            folder = try TemporaryFolder()
            keychain = InMemoryKeychain(values: Dictionary(uniqueKeysWithValues: tokens.map { ($0.key.rawValue, $0.value) }))
            log = ActivityLog(folder: folder.file("Logs"))
            teamStore = TeamStore(folder: folder.url, report: { _ in })
            if team != TeamValues() {
                try teamStore.save(Project(id: .main, team: team))
            }
            store = SettingsStore(
                preferences: PreferencesStore(defaults: suite.defaults),
                team: teamStore,
                tokens: TokenStore(keychain: keychain, log: log),
                launchAtLogin: LaunchAtLogin(item: loginItem, log: log),
                log: log,
                transport: { _ in stub },
                clock: clock,
                checkNow: { await calls.checkNow() },
                setCheckInterval: { await calls.setCheckInterval($0) })
        }

        /// The messages of the log, oldest first, once the store logged its changes.
        func messages() async -> [String] {
            await store.waitUntilSettled()
            return await log.entries().map(\.message)
        }

        /// Lets the pause before the team values are saved pass.
        func pauseTyping() async {
            await clock.waitForSleepers()
            clock.advance(by: SettingsStore.teamSaveDelay)
            await store.waitUntilSettled()
        }
    }

    // MARK: - SET-01, SET-02

    @Test("SET-01 logs a change once and never a token")
    func logsAChangeOnce() async throws {
        let harness = try Harness()
        let store = harness.store

        store.preferences.alertStyle = .banner
        store.preferences.alertStyle = .banner
        store.preferences.showInMenuBar = false
        store.setLabel("evil::$(touch pwned)", in: .with)
        _ = await store.saveGitLabToken(Self.gitLabToken)
        _ = await store.saveJenkinsToken(user: "jdoe", apiToken: "secret-api-token")

        let messages = await harness.messages()
        #expect(messages == [
            "alertStyle: window → banner",
            "showInMenuBar: on → off",
            "Work items must have the label evil::$(touch pwned)",
            "Saved the GitLab token in the keychain",
            "Saved the Jenkins token in the keychain",
        ])
        let entries = await harness.log.entries()
        #expect(entries.allSatisfy { $0.level == .info && $0.source == .settings })
        let file = try String(contentsOf: harness.log.fileURL, encoding: .utf8)
        for secret in [Self.gitLabToken, Self.jenkinsToken, "secret-api-token"] {
            #expect(!file.contains(secret))
        }
        #expect(PreferencesStore(defaults: harness.suite.defaults).load() == store.preferences)
        #expect(!store.preferences.showInMenuBar)
    }

    @Test("SET-01 logs an emptied value as (empty)")
    func logsEmpty() async throws {
        let harness = try Harness()
        harness.store.setLabel("bug", in: .with)
        harness.store.preferences.workItems.withLabels = []

        #expect(await harness.messages() == ["Work items must have the label bug", "workItemsWithLabels: bug → (empty)"])
    }

    @Test("SET-01 changing the interval reschedules the check")
    func intervalReschedules() async throws {
        let harness = try Harness()
        let scheduler = Scheduler(
            checkInterval: .seconds(60), clock: harness.clock, systemEvents: FakeSystemEvents(),
            reachability: FakeReachability(), powerMode: FakePowerMode(), check: { _ in .success })
        let store = SettingsStore(
            preferences: PreferencesStore(defaults: harness.suite.defaults), team: harness.teamStore,
            tokens: TokenStore(keychain: harness.keychain), launchAtLogin: LaunchAtLogin(item: harness.loginItem),
            log: harness.log, transport: { _ in StubTransport() }, clock: harness.clock, checkNow: {},
            setCheckInterval: { await scheduler.setCheckInterval($0) })

        store.preferences.iconStyle = .color
        await store.waitUntilSettled()
        #expect(await scheduler.nextWait == .seconds(60))
        store.preferences.checkIntervalSeconds = 300
        await store.waitUntilSettled()
        #expect(await scheduler.nextWait == .seconds(300))

        // The test harness's own store tells the app the same way.
        harness.store.preferences.checkIntervalSeconds = 120
        harness.store.preferences.checkIntervalSeconds = 45
        await harness.store.waitUntilSettled()
        #expect(await harness.calls.intervals == [.seconds(120), .seconds(60)])
        #expect(harness.store.preferences.checkIntervalSeconds == 60)
    }

    @Test("SET-01 a change takes effect without a restart")
    func takesEffect() async throws {
        let harness = try Harness()
        final class Seen {
            var preferences: [Preferences] = []
        }
        let seen = Seen()
        harness.store.preferencesChanged = { seen.preferences.append($0) }

        harness.store.preferences.hideSuccessfulAfter = .immediately
        harness.store.preferences.hideSuccessfulAfter = .immediately
        harness.store.preferences.fillInCopiedLink = true

        // Setting a value it already has changes nothing.
        #expect(seen.preferences.count == 2)
        #expect(seen.preferences.last?.hideSuccessfulAfter == .immediately)
        #expect(seen.preferences.last?.fillInCopiedLink == true)
        #expect(PreferencesStore(defaults: harness.suite.defaults).load().hideSuccessfulAfter == .immediately)
    }

    @Test("SET-02 problem rows open the matching pane")
    func problemRowsOpenThePane() throws {
        let harness = try Harness()
        let store = harness.store
        let cases: [(Problem, SettingsPane?)] = [
            (.noToken(.jenkins), .accounts), (.noToken(.gitLab), .accounts), (.rejectedToken(.gitLab), .accounts),
            (.missingScope, .accounts), (.teamValuesMissing, .team), (.unknownJob, .team), (.unreachable(.jenkins), nil),
            (.slow, nil), (.httpStatus(.gitLab, status: 500), nil), (.gone, nil),
        ]
        for (problem, pane) in cases {
            #expect(SettingsPane.pane(for: problem) == pane)
        }
        #expect(store.selectedPane == .general)
        #expect(store.selectPane(for: .noToken(.jenkins)))
        #expect(store.selectedPane == .accounts)
        #expect(!store.selectPane(for: .slow))
        #expect(store.selectedPane == .accounts)
        #expect(SettingsPane.allCases.map(\.title) == ["General", "Jenkins", "GitLab", "Repositories", "Projects", "Accounts"])
    }

    @Test("SET-02 Settings opens at the pane it showed last, also after a restart")
    func remembersThePane() throws {
        let harness = try Harness()

        harness.store.selectedPane = .team

        #expect(harness.suite.defaults.string(forKey: SettingsStore.selectedPaneKey) == "team")
        #expect(Self.restarted(harness).selectedPane == .team)
        harness.suite.defaults.set("nonsense", forKey: SettingsStore.selectedPaneKey)
        #expect(Self.restarted(harness).selectedPane == .general)
        // The removed Watching pane, stored by an earlier version, opens General.
        harness.suite.defaults.set("watching", forKey: SettingsStore.selectedPaneKey)
        #expect(Self.restarted(harness).selectedPane == .general)
    }

    /// A new store over the same suite, folder and keychain, as after a restart.
    private static func restarted(_ harness: Harness) -> SettingsStore {
        let stub = harness.stub
        return SettingsStore(
            preferences: PreferencesStore(defaults: harness.suite.defaults), team: harness.teamStore,
            tokens: TokenStore(keychain: harness.keychain, log: harness.log),
            launchAtLogin: LaunchAtLogin(item: harness.loginItem, log: harness.log), log: harness.log,
            transport: { _ in stub }, checkNow: {}, setCheckInterval: { _ in })
    }

    // MARK: - TEAM-01 to TEAM-03

    @Test("TEAM-01 saves a team value trimmed")
    func savesTrimmed() async throws {
        let harness = try Harness()
        let store = harness.store

        store.teamDraft.gitLabProject = "  group/project \n"
        await harness.clock.waitForSleepers()
        harness.clock.advance(by: .milliseconds(599))
        #expect(store.team.gitLabProject == "team/product")
        harness.clock.advance(by: .milliseconds(1))
        await store.waitUntilSettled()

        #expect(store.team.gitLabProject == "group/project")
        #expect(harness.teamStore.primaryProject().team.gitLabProject == "group/project")
        // The field keeps what was typed.
        #expect(store.teamDraft.gitLabProject == "  group/project \n")
        #expect(await harness.calls.checks == 1)
    }

    @Test("TEAM-01 typing again waits for the next pause")
    func typingWaits() async throws {
        let harness = try Harness()
        let store = harness.store

        store.teamDraft.committedLabel = "comm"
        await harness.clock.waitForSleepers()
        harness.clock.advance(by: .milliseconds(400))
        store.teamDraft.committedLabel = "committed"
        await harness.pauseTyping()

        #expect(store.team.committedLabel == "committed")
        #expect(await harness.messages() == ["Team committedLabel: (empty) → committed"])
    }

    @Test("TEAM-01 drops the trailing slash of the URLs")
    func dropsTrailingSlash() async throws {
        let harness = try Harness(team: TeamValues())
        let store = harness.store

        store.teamDraft.gitLabURL = " https://gitlab.example.com/ "
        store.teamDraft.jenkinsJobURL = Self.jobURL + "//"
        store.saveTeamNow()

        #expect(store.team.gitLabURL == "https://gitlab.example.com")
        #expect(store.team.jenkinsJobURL == Self.jobURL)
        #expect(harness.teamStore.primaryProject().team.gitLabURL == "https://gitlab.example.com")
    }

    @Test("TEAM-01 refuses a URL that is not http")
    func refusesNonHTTP() async throws {
        let harness = try Harness()
        let store = harness.store

        for url in ["ftp://jenkins.example.com/job/x", "jenkins.example.com/job/x", "https://", "file:///tmp/x"] {
            store.teamDraft.jenkinsJobURL = url
            #expect(store.teamIssue(for: .jenkinsJobURL) == "Enter a URL that starts with https:// or http://")
        }
        store.teamDraft.gitLabProject = "project"
        #expect(store.teamIssue(for: .gitLabProject) == "Enter the project's path, like group/project")
        store.teamDraft.gitLabURL = "http://gitlab.example.com"
        #expect(store.teamIssue(for: .gitLabURL) == nil)
        await harness.pauseTyping()

        // Only the valid value is saved; the others keep their saved value.
        #expect(store.team == TeamValues(jenkinsJobURL: Self.jobURL, gitLabURL: "http://gitlab.example.com", gitLabProject: "team/product"))
        #expect(await harness.messages() == ["Team gitLabURL: https://gitlab.example.com → http://gitlab.example.com"])
        store.teamDraft.jenkinsJobURL = ""
        #expect(store.teamIssue(for: .jenkinsJobURL) == nil)
        #expect(store.teamIssue(for: .committedLabel) == nil)
    }

    @Test("TEAM-01 logs a team change on one line")
    func logsOnOneLine() async throws {
        let harness = try Harness()
        harness.store.teamDraft.ignoredMergeRequestPrefix = "[cascade]\tskip\nthis"
        harness.store.saveTeamNow()

        await harness.store.waitUntilSettled()
        let entries = await harness.log.entries()
        #expect(entries.map(\.message) == ["Team ignoredMergeRequestPrefix: (empty) → [cascade] skip this"])
        #expect(entries.first?.source == .settings && entries.first?.level == .info)
        let file = try String(contentsOf: harness.log.fileURL, encoding: .utf8)
        #expect(file.split(separator: "\n").count == 1)
    }

    @Test("TEAM-02 import through Settings logs the changed values and starts a check")
    func importsThroughSettings() async throws {
        let harness = try Harness(team: TeamValues())
        let store = harness.store
        store.teamDraft.committedLabel = "pending edit"

        try store.importTeamFile(from: FixtureFiles.url("../../team.example.json"))

        #expect(store.team == harness.teamStore.primaryProject().team)
        #expect(store.teamDraft == store.team)
        #expect(store.missingTeamValues.isEmpty)
        let messages = await harness.messages()
        #expect(messages.first == "Imported the team values from team.example.json")
        #expect(messages.dropFirst().allSatisfy { $0.hasPrefix("Team ") })
        #expect(await harness.calls.checks == 1)

        let exported = harness.folder.file("exported.json")
        try store.exportTeamFile(to: exported)
        #expect(try TeamStore.readTeamFile(from: exported) == store.team)
        let newer = try harness.folder.write(#"{"formatVersion": 99, "team": {}}"#, to: "newer.json")
        #expect(throws: TeamFileError.newerFormat(99)) {
            try store.importTeamFile(from: newer)
        }
    }

    @Test("TEAM-03 asks for the team values and makes no request")
    func asksForTeamValues() async throws {
        let harness = try Harness(team: TeamValues(), tokens: [.jenkins: Self.jenkinsToken, .gitlab: Self.gitLabToken])
        let store = harness.store

        #expect(store.missingTeamValues == [.jenkinsJobURL, .gitLabURL, .gitLabProject])
        await store.checkAccounts()

        #expect(store.accounts[.jenkins]?.message == "Set the Jenkins job in Team first")
        #expect(store.accounts[.gitlab]?.message == "Set the GitLab URL in Team first")
        #expect(harness.stub.requests.isEmpty)
        #expect(store.tokenLink(.jenkins) == nil && store.tokenLink(.gitlab) == nil)
    }

    /// Also: a finished or closed flow opens again only while a value is missing, at this launch and the next one.
    @Test("TEAM-03 missing values start the welcome flow", arguments: [false, true])
    func missingValuesStartTheWelcomeFlow(closedEarlier: Bool) async throws {
        let harness = try Harness(team: TeamValues(jenkinsJobURL: Self.jobURL))
        let store = harness.store
        if closedEarlier {
            store.completeWelcomeFlow()
        }
        #expect(store.needsWelcomeFlow)

        store.teamDraft.gitLabURL = "https://gitlab.example.com"
        store.saveTeamNow()
        #expect(store.missingTeamValues == [.gitLabProject])
        #expect(store.needsWelcomeFlow)
        store.teamDraft.gitLabProject = "team/product"
        store.saveTeamNow()
        // With the values saved, only a flow that was never finished or closed opens: the first start.
        #expect(store.needsWelcomeFlow == !closedEarlier)

        func nextLaunch() -> SettingsStore {
            SettingsStore(
                preferences: PreferencesStore(defaults: harness.suite.defaults), team: harness.teamStore,
                tokens: TokenStore(keychain: harness.keychain), launchAtLogin: LaunchAtLogin(item: harness.loginItem),
                log: nil, transport: { _ in StubTransport() }, checkNow: {}, setCheckInterval: { _ in })
        }
        let next = nextLaunch()
        #expect(next.needsWelcomeFlow == !closedEarlier)
        next.completeWelcomeFlow()
        #expect(!nextLaunch().needsWelcomeFlow)
        // A value removed later brings it back.
        try harness.teamStore.save(Project(id: .main, team: TeamValues(jenkinsJobURL: Self.jobURL)))
        #expect(nextLaunch().needsWelcomeFlow)
    }

    // MARK: - ACC-04 to ACC-06

    @Test("ACC-04 says who is signed in")
    func saysWhoIsSignedIn() async throws {
        let harness = try Harness(tokens: [.jenkins: Self.jenkinsToken, .gitlab: Self.gitLabToken])
        harness.stub.answer(path: Self.jobPath, body: try FixtureFiles.string("Jenkins/account.json"))
        harness.stub.answer(operation: "CurrentUser", body: try FixtureFiles.string("GitLab/current-user.json"))

        await harness.store.checkAccounts()

        #expect(harness.store.accounts[.jenkins] == AccountStatus(ok: true, message: "Signed in as jdoe"))
        #expect(harness.store.accounts[.gitlab] == AccountStatus(ok: true, message: "Signed in as alex.doe"))
        #expect(!harness.store.isCheckingAccounts)
        #expect(harness.stub.requests(path: Self.jobPath).map(\.headers["Authorization"]) == ["Basic \(Self.jenkinsToken)"])
        #expect(harness.stub.requests(operation: "CurrentUser").map(\.headers["Authorization"]) == ["Bearer \(Self.gitLabToken)"])
    }

    @Test("ACC-07 the account check notes a GitLab token that can only read, and not one that says nothing of its scopes")
    func notesAReadOnlyToken() async throws {
        let harness = try Harness(tokens: [.jenkins: Self.jenkinsToken, .gitlab: Self.gitLabToken])
        harness.stub.answer(path: Self.jobPath, body: try FixtureFiles.string("Jenkins/account.json"))
        harness.stub.answer(operation: "CurrentUser", body: try FixtureFiles.string("GitLab/current-user.json"))
        harness.stub.answer("GET", path: "/api/v4/personal_access_tokens/self", body: #"{"scopes":["read_api"]}"#)

        await harness.store.checkAccounts()

        #expect(harness.store.accounts[.gitlab] == AccountStatus(
            ok: true, message: "Signed in as alex.doe. The token can only read: re-requesting a review needs the api scope"))

        // A token that has api, or a GitLab that doesn't answer the scope check, is just signed in.
        harness.stub.answer("GET", path: "/api/v4/personal_access_tokens/self", body: #"{"scopes":["api"]}"#)
        await harness.store.checkAccounts()
        #expect(harness.store.accounts[.gitlab] == AccountStatus(ok: true, message: "Signed in as alex.doe"))
        harness.stub.answer("GET", path: "/api/v4/personal_access_tokens/self", status: 404)
        await harness.store.checkAccounts()
        #expect(harness.store.accounts[.gitlab] == AccountStatus(ok: true, message: "Signed in as alex.doe"))
    }

    @Test("ACC-04 tells a rejected Jenkins token and a rejected GitLab token")
    func tellsRejectedTokens() async throws {
        let harness = try Harness(tokens: [.jenkins: Self.jenkinsToken, .gitlab: Self.gitLabToken])
        harness.stub.answer(path: Self.jobPath, status: 401, body: try FixtureFiles.string("Jenkins/error-401.html"))
        harness.stub.answer(operation: "CurrentUser", body: try FixtureFiles.string("GitLab/current-user-null.json"))

        await harness.store.checkAccounts()

        #expect(harness.store.accounts[.jenkins] == AccountStatus(ok: false, message: "Jenkins rejected the token"))
        #expect(harness.store.accounts[.gitlab] == AccountStatus(
            ok: false, message: "GitLab rejected the token (expired, or without the api scope?)"))
    }

    @Test("ACC-04 tells GitLab unreachable")
    func tellsGitLabUnreachable() async throws {
        let harness = try Harness(tokens: [.jenkins: Self.jenkinsToken, .gitlab: Self.gitLabToken])
        harness.stub.fail(path: Self.jobPath, with: .noConnection(within: .seconds(5)))
        harness.stub.fail(operation: "CurrentUser", with: .unknownHost)

        await harness.store.checkAccounts()

        #expect(harness.store.accounts[.jenkins]?.message == "Jenkins unreachable (VPN?)")
        #expect(harness.store.accounts[.gitlab] == AccountStatus(ok: false, message: "GitLab unreachable"))

        harness.stub.answer(operation: "CurrentUser", status: 502)
        await harness.store.checkAccounts()
        #expect(harness.store.accounts[.gitlab]?.message == "GitLab answered with HTTP 502")
    }

    @Test("ACC-04 tells a missing token")
    func tellsAMissingToken() async throws {
        let harness = try Harness()

        await harness.store.checkAccounts()

        #expect(harness.store.accounts[.jenkins] == .noToken)
        #expect(harness.store.accounts[.gitlab] == AccountStatus(ok: false, message: "No token yet"))
        #expect(harness.stub.requests.isEmpty)
    }

    @Test("ACC-04 asks for the team values first")
    func asksForTheTeamValuesFirst() async throws {
        let harness = try Harness(team: TeamValues(gitLabProject: "team/product"))
        harness.store.teamDraft.jenkinsJobURL = Self.jobURL

        await harness.store.checkAccounts()

        // The edit that waited for typing to pause is saved first; GitLab still lacks its URL, and both lack a token.
        #expect(harness.store.team.jenkinsJobURL == Self.jobURL)
        #expect(harness.store.accounts[.jenkins]?.message == "No token yet")
        #expect(harness.store.accounts[.gitlab]?.message == "Set the GitLab URL in Team first")
        #expect(harness.stub.requests.isEmpty)
    }

    @Test("ACC-04 logs the result")
    func logsTheResult() async throws {
        let harness = try Harness(tokens: [.jenkins: Self.jenkinsToken, .gitlab: Self.gitLabToken])
        harness.stub.answer(path: Self.jobPath, body: try FixtureFiles.string("Jenkins/account.json"))
        harness.stub.answer(operation: "CurrentUser", status: 401, body: try FixtureFiles.string("GitLab/invalid-token.json"))

        await harness.store.checkAccounts()
        await harness.store.waitUntilSettled()

        let entries = await harness.log.entries()
        #expect(entries.map(\.message) == [
            "Account check: Signed in as jdoe",
            "Account check: GitLab rejected the token (expired, or without the api scope?)",
        ])
        #expect(entries.map(\.level) == [.info, .warning])
        #expect(entries.map(\.source) == [.jenkins, .gitlab])
        #expect(entries.map { $0.outcome?.description } == ["ok:OK", "failed:FAILED"])
    }

    @Test("ACC-04 checks by itself after a save and on the first showing")
    func checksByItself() async throws {
        let harness = try Harness(tokens: [.jenkins: Self.jenkinsToken])
        harness.stub.answer(path: Self.jobPath, body: try FixtureFiles.string("Jenkins/account.json"))
        harness.stub.answer(operation: "CurrentUser", body: try FixtureFiles.string("GitLab/current-user.json"))
        let store = harness.store
        await store.loadTokens()

        // A save while no view of the check shows starts only the check of ACC-06.
        #expect(await store.saveGitLabToken(Self.gitLabToken))
        #expect(harness.stub.requests.isEmpty)

        // The first showing with a token stored checks; showing again in the same session doesn't.
        await store.accountsAppeared()
        #expect(store.accounts[.jenkins] == AccountStatus(ok: true, message: "Signed in as jdoe"))
        #expect(harness.stub.requests(path: Self.jobPath).count == 1)
        store.accountsDisappeared()
        await store.accountsAppeared()
        #expect(harness.stub.requests(path: Self.jobPath).count == 1)

        // A save while it shows checks again, beside the check of ACC-06.
        #expect(await store.saveGitLabToken(Self.gitLabToken))
        #expect(store.accounts[.gitlab] == AccountStatus(ok: true, message: "Signed in as alex.doe"))
        #expect(harness.stub.requests(operation: "CurrentUser").count == 2)
        #expect(await harness.calls.checks == 2)

        // Without a stored token, the first showing asks nothing.
        let empty = try Harness()
        await empty.store.loadTokens()
        await empty.store.accountsAppeared()
        #expect(empty.store.accounts.isEmpty)
        #expect(empty.stub.requests.isEmpty)
    }

    @Test("ACC-05 Jenkins token link is the user page")
    func jenkinsTokenLink() throws {
        let harness = try Harness()

        let link = try #require(harness.store.tokenLink(.jenkins))
        #expect(link.url.absoluteString == "https://jenkins.example.com/jenkins/me/")
        #expect(link.title == "Get a token: your user page → Security")
        let root = TokenLink.create(.jenkins, team: TeamValues(jenkinsJobURL: "https://jenkins.example.com/job/mrs/"))
        #expect(root?.url.absoluteString == "https://jenkins.example.com/me/")
        let noJob = TokenLink.create(.jenkins, team: TeamValues(jenkinsJobURL: "https://jenkins.example.com/view/all"))
        #expect(noJob?.url.absoluteString == "https://jenkins.example.com/view/all/me/")
    }

    @Test("ACC-05 GitLab token link is prefilled")
    func gitLabTokenLink() throws {
        let harness = try Harness()

        let link = try #require(harness.store.tokenLink(.gitlab))
        #expect(link.url == GitLabLinks.newToken(gitLab: URL(string: "https://gitlab.example.com")!))
        #expect(link.url.absoluteString
            == "https://gitlab.example.com/-/user_settings/personal_access_tokens?name=menubar-monitor&scopes=api")
        #expect(link.title == "Create a token with the api scope")
    }

    @Test("ACC-05 no link without the team value")
    func noLinkWithoutTheTeamValue() throws {
        #expect(TokenLink.create(.jenkins, team: TeamValues(gitLabURL: "https://gitlab.example.com")) == nil)
        #expect(TokenLink.create(.gitlab, team: TeamValues(jenkinsJobURL: Self.jobURL)) == nil)
        #expect(TokenLink.create(.jenkins, team: TeamValues(jenkinsJobURL: "jenkins.example.com/job/x")) == nil)
        let harness = try Harness(team: TeamValues())
        #expect(harness.store.tokenLink(.jenkins) == nil)
    }

    @Test("ACC-06 saving a token starts a check")
    func savingStartsACheck() async throws {
        let harness = try Harness()
        let store = harness.store

        #expect(await store.saveGitLabToken("  \(Self.gitLabToken)\n"))
        #expect(await harness.calls.checks == 1)
        #expect(await harness.keychain.values[TokenAccount.gitlab.rawValue] == Self.gitLabToken)
        #expect(store.storedTokens == [.gitlab])

        #expect(await store.saveGitLabToken("glpat with spaces") == false)
        #expect(store.tokenErrors[.gitlab] == "That does not look like a token: it has spaces or quotes")
        #expect(await store.saveJenkinsToken(user: "jdoe", apiToken: "has \"quotes\"") == false)
        #expect(store.tokenErrors[.jenkins] == "That does not look like a token: it has spaces or quotes")
        #expect(await harness.calls.checks == 1)

        await store.removeToken(.gitlab)
        #expect(await harness.calls.checks == 2)
        #expect(store.storedTokens.isEmpty)
        #expect(store.tokenSource(.gitlab) == .missing(nil))
    }

    @Test("MR-04 removing a token tells the app which one")
    func removingATokenTellsTheApp() async throws {
        let harness = try Harness(tokens: [.jenkins: Self.jenkinsToken, .gitlab: Self.gitLabToken])
        let store = harness.store
        final class Seen {
            var removed: [TokenAccount] = []
        }
        let seen = Seen()
        let calls = harness.calls
        store.onTokenRemoved = { account in
            seen.removed.append(account)
        }
        await store.loadTokens()

        #expect(await store.saveGitLabToken(Self.gitLabToken))
        #expect(seen.removed.isEmpty)
        let checks = await calls.checks

        await store.removeToken(.gitlab)

        #expect(seen.removed == [.gitlab])
        #expect(await calls.checks == checks + 1)
        await store.removeToken(.jenkins)
        #expect(seen.removed == [.gitlab, .jenkins])
    }

    @Test("ACC-06 prefills the Jenkins user and saves user and token as base64")
    func prefillsTheJenkinsUser() async throws {
        let harness = try Harness(tokens: [.jenkins: Self.jenkinsToken])
        let store = harness.store

        await store.loadTokens()
        #expect(store.jenkinsUser == "jdoe")
        #expect(store.storedTokens == [.jenkins])
        #expect(!SettingsStore.canSaveJenkinsToken(user: "jdoe", apiToken: "  "))
        #expect(!SettingsStore.canSaveJenkinsToken(user: " ", apiToken: "token"))
        #expect(SettingsStore.canSaveJenkinsToken(user: "jdoe", apiToken: "token"))
        #expect(!SettingsStore.canSaveGitLabToken("\n"))

        #expect(await store.saveJenkinsToken(user: " asmith ", apiToken: " new-token "))
        #expect(await harness.keychain.values[TokenAccount.jenkins.rawValue] == TokenStore.jenkinsToken(user: "asmith", apiToken: "new-token"))
        #expect(store.jenkinsUser == "asmith")
    }

    @Test("ACC-02 Settings tells where each token comes from")
    func tellsWhereTokensComeFrom() async throws {
        let harness = try Harness(tokens: [.jenkins: Self.jenkinsToken])
        let store = harness.store
        store.importReport = LegacyImportReport(
            date: Date(), tokens: [
                TokenImport(account: .jenkins, outcome: .imported(.zshrc)),
                TokenImport(account: .gitlab, outcome: .notFound(.zshrcComputed)),
            ])
        await store.loadTokens()

        #expect(store.tokenSource(.jenkins) == .keychain(importedFrom: .zshrc))
        #expect(store.tokenSource(.jenkins).text == "Keychain, imported from ~/.zshrc")
        #expect(store.tokenSource(.gitlab).text == "~/.zshrc computes it, which the app cannot run: paste it here")
        _ = await store.saveGitLabToken(Self.gitLabToken)
        #expect(store.tokenSource(.gitlab) == .keychain(importedFrom: nil))
        #expect(store.tokenSource(.gitlab).text == "Keychain")
    }

    // MARK: - APP-02

    @Test("APP-02 Settings turns open at login on and off and shows the status")
    func openAtLogin() async throws {
        let harness = try Harness()
        let store = harness.store
        #expect(store.openAtLogin == .notRegistered)

        harness.loginItem.statusAfterRegister = .requiresApproval
        await store.setOpenAtLogin(true)
        #expect(store.openAtLogin == .requiresApproval)
        #expect(store.openAtLogin.isOn)
        store.openLoginItemsSettings()
        await store.setOpenAtLogin(false)
        #expect(store.openAtLogin == .notRegistered)
        #expect(harness.loginItem.calls == [.register, .openSystemSettings, .unregister])

        harness.loginItem.error = LoginItemError(turningOn: true, reason: "test")
        await store.setOpenAtLogin(true)
        #expect(store.openAtLogin == .notRegistered)
        #expect(store.openAtLoginError?.hasPrefix("Open at login couldn't be turned on") == true)
    }

    // MARK: - Projects (PROJ-02)

    @Test("PROJ-02 Settings adds, edits and removes another project, and never the primary one")
    func managesProjects() async throws {
        let harness = try Harness()
        let store = harness.store
        var changes: [ProjectID?] = []
        store.projectsChanged = { changes.append($0) }
        var client = Self.team
        client.jenkinsJobURL = "https://jenkins.example.com/jenkins/job/GitLab%20Team/job/team%252Fclient"
        client.gitLabProject = "team/client"

        try store.addProject(client)
        let added = try #require(harness.teamStore.projects().last?.id)
        #expect(store.projectID == added)
        #expect(!store.editsPrimaryProject)
        #expect(store.team == client)
        #expect(store.primaryTeam == Self.team)
        #expect(store.missingTeamValues.isEmpty)

        // An edit that would move the project to another Jenkins is refused, and the stored values stay.
        store.teamDraft.jenkinsJobURL = "https://ci.example.org/job/client"
        store.saveTeamNow()
        #expect(store.teamError?.contains("Uses another Jenkins than product") == true)
        #expect(harness.teamStore.project(added)?.team == client)

        store.teamDraft.committedLabel = "Done"
        store.teamDraft.jenkinsJobURL = client.jenkinsJobURL
        store.saveTeamNow()
        #expect(harness.teamStore.project(added)?.team.committedLabel == "Done")
        #expect(harness.teamStore.primaryProject().team == Self.team)

        #expect(throws: ProjectError.primary) { try store.removeProject(.main) }
        try store.removeProject(added)
        #expect(store.projectID == .main)
        #expect(store.team == Self.team)
        #expect(harness.teamStore.projects().map(\.id) == [.main])
        #expect(changes == [nil, nil, added])
        let messages = await harness.messages()
        #expect(messages.contains("Added the project client: team/client"))
        #expect(messages.contains("client Team committedLabel: (empty) → Done"))
        #expect(messages.contains("Removed the project client"))
    }
}
