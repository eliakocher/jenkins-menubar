import AppKit
import Foundation
import MenubarCore
import Observation
import SwiftUI

/// What the welcome flow needs from the app, which `MenubarUI` can't see: the notification permission and the import
/// of a chosen folder.
public struct WelcomeActions {
    /// reads what macOS answered about notifications
    public var notificationPermission: @MainActor () async -> NotificationPermission
    /// asks macOS for the permission, with banners and sounds, and returns the answer (APP-04)
    public var requestNotificationPermission: @MainActor () async -> NotificationPermission
    /// opens System Settings → Notifications at the app
    public var openNotificationSettings: @MainActor () -> Void
    /// imports from the old tool's folder that people chose (IMP-01), then hands the new report to the settings
    public var importOldFolder: @MainActor (URL) async -> Void

    public init(
        notificationPermission: @escaping @MainActor () async -> NotificationPermission,
        requestNotificationPermission: @escaping @MainActor () async -> NotificationPermission,
        openNotificationSettings: @escaping @MainActor () -> Void,
        importOldFolder: @escaping @MainActor (URL) async -> Void
    ) {
        self.notificationPermission = notificationPermission
        self.requestNotificationPermission = requestNotificationPermission
        self.openNotificationSettings = openNotificationSettings
        self.importOldFolder = importOldFolder
    }
}

/// The welcome flow at first start (Task 6.4, `docs/design/welcome.md`): what the import brought, the team values, the
/// tokens, the notification permission, the menu bar item and open at login, and what is still missing or didn't move.
///
/// It reads `SettingsStore` from the environment, so the flow and Settings never differ. Each step saves as it goes;
/// closing the window, early too, saves the team values that wait for typing to pause and counts as finished: the flow
/// then opens again only while a required team value is missing (TEAM-03).
public struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @ViewState private var flow = WelcomeFlow()
    private let actions: WelcomeActions

    /// - Parameter actions: what the app does for the flow
    public init(actions: WelcomeActions) {
        self.actions = actions
    }

    public var body: some View {
        WelcomeContent(data: flow.data(settings: settings), input: input, actions: contentActions)
            .onAppear {
                flow.appeared(
                    settings: settings, actions: actions, finishedBefore: model.preferencesStore.welcomeCompleted)
            }
            .onChange(of: flow.page) { old, _ in
                flow.pageChanged(from: old, settings: settings, actions: actions)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // System Settings may have approved the login item or changed the notifications meanwhile.
                flow.becameActive(settings: settings, actions: actions)
            }
            .onDisappear {
                flow.disappeared(settings: settings)
            }
    }

    /// The fields and switches, bound to the settings where they save at once, and to the flow where they wait for
    /// Continue.
    private var input: Binding<WelcomeInput> {
        Binding {
            WelcomeInput(
                team: settings.teamDraft, jenkinsUser: flow.jenkinsUser, jenkinsToken: flow.jenkinsToken,
                gitLabToken: flow.gitLabToken, showInMenuBar: settings.preferences.showInMenuBar,
                openAtLogin: flow.openAtLogin)
        } set: { new in
            if new.team != settings.teamDraft {
                flow.typing(TeamValues.Key.allCases.filter { new.team[$0] != settings.teamDraft[$0] })
                settings.teamDraft = new.team
            }
            flow.jenkinsUser = new.jenkinsUser
            flow.jenkinsToken = new.jenkinsToken
            flow.gitLabToken = new.gitLabToken
            flow.openAtLogin = new.openAtLogin
            if new.showInMenuBar != settings.preferences.showInMenuBar {
                settings.preferences.showInMenuBar = new.showInMenuBar
            }
        }
    }

    private var contentActions: WelcomeContentActions {
        let settings = settings
        let flow = flow
        let actions = actions
        let dismiss = dismiss
        return WelcomeContentActions(
            next: {
                flow.perform {
                    if await flow.next(settings: settings, actions: actions) {
                        dismiss()
                    }
                }
            },
            back: { flow.back() },
            importTeamFile: { flow.importTeamFile($0, settings: settings) },
            leftTeamField: { flow.leftTeamField($0, settings: settings) },
            teamNotReady: { flow.teamNotReady() },
            chooseFolder: { folder in Task { await flow.chooseFolder(folder, actions: actions) } },
            saveToken: { account in flow.perform { await flow.save(account, settings: settings) } },
            removeToken: { account in Task { await settings.removeToken(account) } },
            checkAccounts: { Task { await settings.checkAccounts() } },
            openNotificationSettings: actions.openNotificationSettings,
            openLoginItemsSettings: { settings.openLoginItemsSettings() })
    }
}

/// The flow's own state beside the settings: the page, what was typed but not saved, and what macOS answered.
@Observable
@MainActor
final class WelcomeFlow {
    var page = WelcomePage.welcome
    var jenkinsUser = ""
    var jenkinsToken = ""
    var gitLabToken = ""
    /// starts on at the first start, and as the login item is when the flow comes back; registered when Continue is
    /// pressed on page 5 (APP-02)
    var openAtLogin = true
    /// what macOS answered; nil until it is read
    var notifications: NotificationPermission?
    /// what Import Team File… did, until the next edit or import
    var teamFileResult: WelcomeLine?
    /// whether the TEAM-03 row is a problem: people tried to move on, or left a required field empty; a note before
    var teamRowIsProblem = false
    /// whether the folder chosen last isn't the old tool's
    var wrongFolder = false
    /// whether the page's button is at work
    var isBusy = false
    /// the team values being typed, whose issues wait until typing pauses (TEAM-01)
    private var typingKeys: Set<TeamValues.Key> = []
    @ObservationIgnored private var typingPause: Task<Void, Never>?

    /// Returns what the content shows now.
    func data(settings: SettingsStore) -> WelcomeData {
        let draft = settings.teamDraft
        var issues: [TeamValues.Key: String] = [:]
        for key in TeamValues.Key.allCases where !typingKeys.contains(key) {
            issues[key] = settings.teamIssue(for: key)
        }
        var notes: [String] = []
        var problems: [String] = []
        if !settings.missingTeamValues.isEmpty {
            if teamRowIsProblem {
                problems.append(Problem.teamValuesMissing.message)
            } else {
                notes.append(Problem.teamValuesMissing.message)
            }
        }
        if let error = settings.teamError {
            problems.append(error)
        }
        var tokenErrors = settings.tokenErrors
        if tokenErrors[.jenkins] == nil, WelcomeAccountRules.needsJenkinsUser(user: jenkinsUser, token: jenkinsToken) {
            tokenErrors[.jenkins] = WelcomeAccountRules.userMissing
        }
        return WelcomeData(
            page: page,
            importSummary: WelcomeImportSummary.make(settings.importReport),
            wrongFolder: wrongFolder,
            team: WelcomeData.Team(
                notes: notes, problems: problems, issues: issues,
                importedFromOldTool: settings.importReport?.importedTeam == true, fileResult: teamFileResult,
                canContinue: WelcomeTeamRules.canContinue(draft: draft) { settings.teamIssue(for: $0) }),
            accounts: WelcomeData.Accounts(
                sources: Dictionary(uniqueKeysWithValues: TokenAccount.allCases.map { ($0, settings.tokenSource($0)) }),
                links: Dictionary(uniqueKeysWithValues: TokenAccount.allCases.compactMap { account in
                    settings.tokenLink(account).map { (account, $0) }
                }),
                errors: tokenErrors, isChecking: settings.isCheckingAccounts, results: settings.accounts),
            notifications: notifications,
            preferences: settings.preferences,
            login: WelcomeData.Login(status: settings.openAtLogin, error: settings.openAtLoginError),
            summary: WelcomeSummary.make(
                report: settings.importReport, storedTokens: settings.storedTokens,
                accounts: settings.isCheckingAccounts ? [:] : settings.accounts, notifications: notifications,
                loginItem: settings.openAtLogin, preferences: settings.preferences,
                teamComplete: settings.missingTeamValues.isEmpty),
            isBusy: isBusy)
    }

    /// Fills in the Jenkins user of the stored token and open at login, and reads the notification permission.
    ///
    /// - Parameters:
    ///   - settings: the settings
    ///   - actions: what the app does for the flow
    ///   - finishedBefore: whether the flow was finished or closed once, so it comes back for a missing team value:
    ///     open at login then starts as the login item is, not against an earlier choice
    func appeared(settings: SettingsStore, actions: WelcomeActions, finishedBefore: Bool) {
        if jenkinsUser.isEmpty {
            jenkinsUser = settings.jenkinsUser
        }
        settings.refreshOpenAtLogin()
        if finishedBefore {
            openAtLogin = settings.openAtLogin.isOn
        }
        pageAppeared(settings: settings, actions: actions)
    }

    /// The app became active again, maybe from System Settings: the login item and the permission are read again.
    func becameActive(settings: SettingsStore, actions: WelcomeActions) {
        settings.refreshOpenAtLogin()
        Task { notifications = await actions.notificationPermission() }
    }

    /// Accounts tells the settings that the account check shows, which runs it the first time with a token stored
    /// (ACC-04); Notifications and the last page read the permission again, since the system's prompt may have been
    /// answered meanwhile.
    func pageAppeared(settings: SettingsStore, actions: WelcomeActions) {
        switch page {
        case .accounts:
            Task { await settings.accountsAppeared() }
        case .welcome, .notifications, .done:
            Task { notifications = await actions.notificationPermission() }
        case .team, .menuBarAndLogin:
            break
        }
    }

    /// Notes that the page changed: the one left goes, the new one appears.
    func pageChanged(from old: WelcomePage, settings: SettingsStore, actions: WelcomeActions) {
        if old == .accounts {
            settings.accountsDisappeared()
        }
        pageAppeared(settings: settings, actions: actions)
    }

    /// The window closed, early too: the team values that wait for typing to pause are saved, and the flow counts as
    /// finished (TEAM-03).
    func disappeared(settings: SettingsStore) {
        if page == .accounts {
            settings.accountsDisappeared()
        }
        settings.saveTeamNow()
        settings.completeWelcomeFlow()
    }

    /// Runs the page's button, or a Save, unless one is at work: Return in a field may reach both the field and the
    /// default button, and the second press must not move on again.
    func perform(_ work: @escaping @MainActor () async -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await work()
            isBusy = false
        }
    }

    /// A team field lost the keyboard focus: its issue shows now (TEAM-01), and a required one left empty turns the
    /// TEAM-03 row into a problem.
    func leftTeamField(_ key: TeamValues.Key, settings: SettingsStore) {
        typingKeys.remove(key)
        if key.isRequired, settings.teamDraft[key].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            teamRowIsProblem = true
        }
    }

    /// People tried to move on from Team without the values: the issues and the TEAM-03 row show as problems now.
    func teamNotReady() {
        typingKeys = []
        teamRowIsProblem = true
    }

    /// Notes that team values are being typed: their issues show once typing pauses (TEAM-01).
    func typing(_ keys: [TeamValues.Key]) {
        typingKeys.formUnion(keys)
        teamFileResult = nil
        typingPause?.cancel()
        typingPause = Task { [weak self] in
            try? await Task.sleep(for: SettingsStore.teamSaveDelay)
            guard !Task.isCancelled else { return }
            self?.typingKeys = []
        }
    }

    /// Goes to the next page once the page's step is done, or finishes the flow.
    ///
    /// - Returns: `true` when the flow is finished and the window closes
    func next(settings: SettingsStore, actions: WelcomeActions) async -> Bool {
        switch page {
        case .welcome:
            break
        case .team:
            // The drafts are saved first; Continue stays on the page if they can't be (TEAM-03).
            typingKeys = []
            settings.saveTeamNow()
            guard settings.missingTeamValues.isEmpty, settings.teamError == nil else {
                teamNotReady()
                return false
            }
        case .accounts:
            // A token typed but not saved is saved first; a refusal keeps the page with its error (ACC-06). A Jenkins
            // token without the user can't be saved yet: the page stays, with its line asking for the user.
            for account in TokenAccount.allCases
            where !typed(account).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if account == .jenkins, WelcomeAccountRules.needsJenkinsUser(user: jenkinsUser, token: jenkinsToken) {
                    return false
                }
                guard await save(account, settings: settings) else { return false }
            }
        case .notifications:
            if notifications == nil {
                notifications = await actions.notificationPermission()
            }
            if notifications == .notAsked {
                // The system's prompt doesn't hold up the flow; the answer arrives while the next page shows.
                Task { notifications = await actions.requestNotificationPermission() }
            }
        case .menuBarAndLogin:
            if settings.openAtLogin != .notFound {
                await settings.setOpenAtLogin(openAtLogin)
                guard settings.openAtLoginError == nil else {
                    // The switch shows what the login item really is, with the problem line under it.
                    openAtLogin = settings.openAtLogin.isOn
                    return false
                }
            }
        case .done:
            settings.completeWelcomeFlow()
            return true
        }
        if let next = page.next {
            page = next
        }
        return false
    }

    func back() {
        if let previous = page.previous {
            page = previous
        }
    }

    /// Saves a typed token, and empties its field once it is stored (ACC-06).
    ///
    /// - Returns: whether it was stored; the settings' `tokenErrors` say why not
    @discardableResult
    func save(_ account: TokenAccount, settings: SettingsStore) async -> Bool {
        let saved: Bool
        switch account {
        case .jenkins:
            saved = await settings.saveJenkinsToken(user: jenkinsUser, apiToken: jenkinsToken)
            if saved { jenkinsToken = "" }
        case .gitlab:
            saved = await settings.saveGitLabToken(gitLabToken)
            if saved { gitLabToken = "" }
        }
        return saved
    }

    /// Reads a team file into Team (TEAM-02); a refusal shows its line under the button.
    func importTeamFile(_ result: Result<URL, any Error>, settings: SettingsStore) {
        typingKeys = []
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            try settings.importTeamFile(from: url)
            teamFileResult = .ok("Imported the team values from \(url.lastPathComponent)")
        } catch let error as TeamFileError {
            teamFileResult = .problem(error.message)
        } catch {
            teamFileResult = .problem(error.localizedDescription)
        }
    }

    /// Imports from the folder people chose; page 1's lines follow the new report (IMP-01). A folder that isn't the old
    /// tool's imports nothing and says so, since the note alone would look as if nothing happened.
    func chooseFolder(_ folder: URL, actions: WelcomeActions) async {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer {
            if scoped { folder.stopAccessingSecurityScopedResource() }
        }
        wrongFolder = !LegacyImport.isOldFolder(folder)
        if !wrongFolder {
            await actions.importOldFolder(folder)
        }
    }

    private func typed(_ account: TokenAccount) -> String {
        account == .jenkins ? jenkinsToken : gitLabToken
    }
}
