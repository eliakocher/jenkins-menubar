import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("WelcomeFlow")
@MainActor
struct WelcomeFlowTests {
    private nonisolated static let team = TeamValues(
        jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: "https://gitlab.example.com",
        gitLabProject: "group/project")

    /// The settings of a fake model, over a temporary folder and a UserDefaults suite of its own, with a fake login
    /// item; both are removed at the end.
    @MainActor
    private final class Harness {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "menubar-monitor-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suiteName = "menubar-monitor-tests.\(UUID().uuidString)"
        let loginItem = FakeLoginItem()
        let settings: SettingsStore

        init() {
            let defaults = UserDefaults(suiteName: suiteName)!
            settings = AppModel(dependencies: .fake(root: root, defaults: defaults, loginItem: loginItem)).settings
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// What the app was asked: the notifications, and the imports of a chosen folder.
    @MainActor
    private final class Notifications {
        var permission: NotificationPermission
        var answer: NotificationPermission
        private(set) var requests = 0
        private(set) var imports: [URL] = []

        init(_ permission: NotificationPermission, answer: NotificationPermission = .allowed) {
            self.permission = permission
            self.answer = answer
        }

        var actions: WelcomeActions {
            WelcomeActions(
                notificationPermission: { self.permission },
                requestNotificationPermission: {
                    self.requests += 1
                    self.permission = self.answer
                    return self.answer
                },
                openNotificationSettings: {},
                importOldFolder: { self.imports.append($0) })
        }
    }

    @Test(
        "TEAM-03 the welcome flow's Continue waits for the three team values",
        arguments: [
            (TeamValues(), false),
            (TeamValues(jenkinsJobURL: WelcomeFlowTests.team.jenkinsJobURL, gitLabURL: WelcomeFlowTests.team.gitLabURL), false),
            (TeamValues(jenkinsJobURL: "jenkins.example.com/job/project", gitLabURL: WelcomeFlowTests.team.gitLabURL, gitLabProject: "group/project"), false),
            (TeamValues(jenkinsJobURL: " \(WelcomeFlowTests.team.jenkinsJobURL)/ ", gitLabURL: WelcomeFlowTests.team.gitLabURL, gitLabProject: "group/project"), true),
        ])
    func teamContinue(draft: TeamValues, enabled: Bool) async {
        let harness = Harness()
        let settings = harness.settings
        settings.teamDraft = draft
        let flow = WelcomeFlow()
        flow.page = .team

        #expect(flow.data(settings: settings).canContinue == enabled)
        // Continue saves the drafts first, without waiting for typing to pause, and moves on only with all three.
        _ = await flow.next(settings: settings, actions: Notifications(.allowed).actions)
        #expect(flow.page == (enabled ? .accounts : .team))
        #expect(settings.missingTeamValues.isEmpty == enabled)
    }

    /// What people did on Team before looking at the TEAM-03 row again.
    enum TeamStep: CaseIterable, Sendable {
        case nothing, leftEmptyJobURL, leftFilledJobURL, leftEmptyOptionalValue, pressedReturn, pressedContinue

        var turnsRed: Bool {
            [.leftEmptyJobURL, .pressedReturn, .pressedContinue].contains(self)
        }
    }

    @Test(
        "TEAM-03 the welcome flow's team row turns red once people try to move on or leave a required field empty",
        arguments: TeamStep.allCases)
    func teamRow(step: TeamStep) async {
        let harness = Harness()
        let settings = harness.settings
        let flow = WelcomeFlow()
        flow.page = .team
        let row = [Problem.teamValuesMissing.message]
        #expect(flow.data(settings: settings).team.notes == row)

        switch step {
        case .nothing:
            break
        case .leftEmptyJobURL:
            flow.leftTeamField(.jenkinsJobURL, settings: settings)
        case .leftFilledJobURL:
            settings.teamDraft = TeamValues(jenkinsJobURL: Self.team.jenkinsJobURL)
            flow.leftTeamField(.jenkinsJobURL, settings: settings)
        case .leftEmptyOptionalValue:
            flow.leftTeamField(.committedLabel, settings: settings)
        case .pressedReturn:
            flow.teamNotReady()
        case .pressedContinue:
            _ = await flow.next(settings: settings, actions: Notifications(.allowed).actions)
        }
        let team = flow.data(settings: settings).team
        #expect(team.notes == (step.turnsRed ? [] : row))
        #expect(team.problems == (step.turnsRed ? row : []))
        #expect(flow.page == .team)
    }

    @Test(
        "ACC-06 the welcome flow asks for the Jenkins user of a typed API token",
        arguments: [("", "11a2b3c4", true), ("  ", "11a2b3c4", true), ("", "", false), ("jdoe", "", false)])
    func jenkinsUser(user: String, token: String, asks: Bool) async {
        let harness = Harness()
        let flow = WelcomeFlow()
        flow.page = .accounts
        flow.jenkinsUser = user
        flow.jenkinsToken = token

        let data = flow.data(settings: harness.settings)
        #expect(data.accounts.errors[.jenkins] == (asks ? WelcomeAccountRules.userMissing : nil))
        // Continue stays enabled, and keeps the page while the line shows.
        #expect(data.canContinue)
        _ = await flow.next(settings: harness.settings, actions: Notifications(.allowed).actions)
        #expect(flow.page == (asks ? .accounts : .notifications))
    }

    @Test("IMP-01 the welcome flow imports only from a folder of the old tool", arguments: [true, false])
    func chooseFolder(isOldFolder: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "menubar-monitor-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "config"), withIntermediateDirectories: true)
        if isOldFolder {
            try Data().write(to: folder.appending(path: "config/settings"))
        }
        let app = Notifications(.allowed)
        let flow = WelcomeFlow()

        await flow.chooseFolder(folder, actions: app.actions)
        #expect(flow.wrongFolder == !isOldFolder)
        #expect(app.imports == (isOldFolder ? [folder] : []))
    }

    @Test(
        "APP-02 a returning welcome flow starts open at login as the login item is",
        arguments: [
            (false, LoginItemStatus.notRegistered, true), (true, .notRegistered, false), (true, .enabled, true),
        ])
    func openAtLoginStart(finishedBefore: Bool, status: LoginItemStatus, on: Bool) {
        let harness = Harness()
        harness.loginItem.status = status
        let flow = WelcomeFlow()

        flow.appeared(
            settings: harness.settings, actions: Notifications(.allowed).actions, finishedBefore: finishedBefore)
        #expect(flow.openAtLogin == on)
    }

    @Test("APP-02 the welcome flow registers open at login when Continue is pressed", arguments: [true, false])
    func registersOpenAtLogin(on: Bool) async {
        let harness = Harness()
        let flow = WelcomeFlow()
        flow.page = .menuBarAndLogin
        // It starts on, and switching it registers nothing yet.
        #expect(flow.openAtLogin)
        flow.openAtLogin = on
        #expect(harness.loginItem.calls.isEmpty)

        _ = await flow.next(settings: harness.settings, actions: Notifications(.allowed).actions)
        #expect(harness.loginItem.calls == (on ? [.register] : []))
        #expect(harness.settings.openAtLogin.isOn == on)
        #expect(flow.page == .done)

        // A refused registration keeps the page with its reason.
        let refused = Harness()
        refused.loginItem.error = CocoaError(.featureUnsupported)
        let again = WelcomeFlow()
        again.page = .menuBarAndLogin
        _ = await again.next(settings: refused.settings, actions: Notifications(.allowed).actions)
        #expect(again.page == .menuBarAndLogin)
        #expect(again.data(settings: refused.settings).login.error?.hasPrefix("Open at login couldn't be turned on") == true)
        // The switch shows what the login item really is: off.
        #expect(!again.openAtLogin)
    }

    @Test(
        "APP-04 the welcome flow asks for notifications on Continue, without waiting for the answer",
        arguments: [NotificationPermission.notAsked, .allowed, .off])
    func asksForNotifications(before: NotificationPermission) async {
        let harness = Harness()
        let notifications = Notifications(before)
        let flow = WelcomeFlow()
        flow.page = .notifications
        flow.pageAppeared(settings: harness.settings, actions: notifications.actions)
        while flow.notifications == nil {
            await Task.yield()
        }
        // While macOS never asked, the page has only its one button.
        #expect(flow.page.showsBack(notifications: flow.notifications) == (before != .notAsked))

        _ = await flow.next(settings: harness.settings, actions: notifications.actions)
        #expect(flow.page == .menuBarAndLogin)
        while before == .notAsked, flow.notifications == .notAsked {
            await Task.yield()
        }
        #expect(notifications.requests == (before == .notAsked ? 1 : 0))
        #expect(flow.notifications == (before == .notAsked ? .allowed : before))
    }

    /// The import's leftovers, as `LegacyImport` lists them in IMP-03's order.
    private nonisolated static let notMoved: [NotMoved] = [
        .notificationSettings, .keychainAccess, .windowPositions, .labelMemoryAndCaches, .teamValues,
        .token(.jenkins, .notFound(.zshrcComputed)), .token(.gitlab, .notFound(.missing)),
    ]

    @Test(
        "IMP-03 the last page leaves out what was fixed since",
        arguments: [
            // Nothing fixed: every leftover, both tokens still missing; macOS never asked.
            ([], NotificationPermission.notAsked, false, WelcomeFlowTests.notMoved),
            // The Jenkins token stored, notifications allowed, the team values entered.
            ([.jenkins], .allowed, true, [.keychainAccess, .windowPositions, .labelMemoryAndCaches, .token(.gitlab, .notFound(.missing))]),
            // Notifications off: Still Missing says so, and Didn't Move doesn't say it again.
            ([.jenkins], .off, true, [.keychainAccess, .windowPositions, .labelMemoryAndCaches, .token(.gitlab, .notFound(.missing))]),
        ] as [(Set<TokenAccount>, NotificationPermission, Bool, [NotMoved])])
    func lastPage(stored: Set<TokenAccount>, notifications: NotificationPermission, teamComplete: Bool, expected: [NotMoved]) {
        let report = LegacyImportReport(date: Date(), oldToolFound: true, notMoved: Self.notMoved)
        var preferences = Preferences()
        preferences.showInMenuBar = false
        let summary = WelcomeSummary.make(
            report: report, storedTokens: stored, notifications: notifications, preferences: preferences,
            teamComplete: teamComplete)

        #expect(summary.didNotMove == expected.map(\.message))
        #expect(summary.heading == "Almost Ready")
        #expect(summary.stillMissing.map(\.text) == [
            stored.contains(.jenkins) ? nil : WelcomeSummary.noJenkinsToken, WelcomeSummary.noGitLabToken,
            notifications == .off ? WelcomeNotificationText.off(preferences) : nil,
        ].compactMap { $0 })
        #expect(summary.whereToFind == "Open MegaMonitor again to see your builds in its window.")

        // Without an import, nothing is listed as not moved; with both tokens, it's ready.
        let fresh = WelcomeSummary.make(
            report: nil, storedTokens: [.jenkins, .gitlab], notifications: .allowed, preferences: Preferences(),
            teamComplete: true)
        #expect(fresh.didNotMove.isEmpty && fresh.stillMissing.isEmpty)
        #expect(fresh.heading == "You're Ready")
    }

    @Test(
        "IMP-03 the last page counts a rejected token as missing",
        arguments: [
            (TokenAccount.jenkins, AccountStatus(ok: false, message: Problem.rejectedToken(.jenkins).message), true),
            (.gitlab, AccountStatus(ok: false, message: Problem.missingScope.message), true),
            // An unreachable server says nothing about the token.
            (.jenkins, AccountStatus(ok: false, message: Problem.unreachable(.jenkins).message), false),
            (.gitlab, .signedIn(as: "jdoe"), false),
        ])
    func rejectedToken(account: TokenAccount, status: AccountStatus, missing: Bool) {
        let summary = WelcomeSummary.make(
            report: nil, storedTokens: [.jenkins, .gitlab], accounts: [account: status], notifications: .allowed,
            preferences: Preferences(), teamComplete: true)

        #expect(summary.heading == (missing ? "Almost Ready" : "You're Ready"))
        #expect(summary.stillMissing == (missing ? [.problem(status.message)] : []))
    }
}
