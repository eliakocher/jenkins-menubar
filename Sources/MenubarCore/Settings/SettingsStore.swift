import Foundation
import Observation

/// The state of the Settings scene: the preferences, the team values, the tokens with the account check, and open at
/// login (SET-01, SET-02, TEAM-01 to TEAM-03, ACC-04 to ACC-06, APP-02).
///
/// Every change is saved at once, except the team values, which are saved when typing pauses. Each change is logged
/// on one line, never a token. Saving a token or the team values starts a check.
@Observable @MainActor
public final class SettingsStore {
    /// how long typing pauses before the team values are saved (TEAM-01)
    public static let teamSaveDelay: Duration = .milliseconds(600)

    /// the UserDefaults key of the pane Settings showed last, in the preferences' suite
    public static let selectedPaneKey = "settingsWindow.pane"

    /// the preferences whose changes Settings logs with the texts of WI-03 when they come from the label filters
    private static let labelKeys: Set<PreferencesStore.Key> = [.workItemsWithLabels, .workItemsWithoutLabels, .workItemsLabelsMatch]

    @ObservationIgnored private let preferencesStore: PreferencesStore
    @ObservationIgnored private let teamStore: TeamStore
    @ObservationIgnored private let tokenStore: TokenStore
    @ObservationIgnored private let launchAtLogin: LaunchAtLogin
    @ObservationIgnored private let log: ActivityLog?
    @ObservationIgnored private let transport: @Sendable (Project) -> any HTTPTransport
    @ObservationIgnored private let timeouts: Timeouts
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let checkNow: @Sendable () async -> Void
    @ObservationIgnored private let setCheckInterval: @Sendable (Duration) async -> Void
    /// the log entries and the effects of the changes, one after the other, in the order of the changes
    @ObservationIgnored private var work: Task<Void, Never>?
    /// the save that waits for typing to pause
    @ObservationIgnored private var teamSave: Task<Void, Never>?
    /// the project Settings → Projects edits; the primary one at the start
    public private(set) var projectID: ProjectID
    /// the primary project's id
    @ObservationIgnored private var primaryID: ProjectID
    /// the tokens entered in Settings since the launch, whose source is no longer the import
    @ObservationIgnored private var enteredTokens: Set<TokenAccount> = []
    /// how many views of the account check show (ACC-04)
    @ObservationIgnored private var accountViews = 0
    /// whether the account check ran in this session, so a later showing doesn't run it by itself
    @ObservationIgnored private var hasCheckedAccounts = false
    /// whether a token was saved while the account check ran, which then asks again
    @ObservationIgnored private var checksAccountsAgain = false

    /// Called after a preference changed, with the preferences now saved; the app passes what doesn't read them
    /// itself.
    @ObservationIgnored public var preferencesChanged: (@MainActor (Preferences) -> Void)?
    /// Called after a token was removed from the keychain, before the check it starts; the app makes the GitLab stores
    /// forget their data for the GitLab token (MR-04).
    @ObservationIgnored public var onTokenRemoved: (@MainActor (TokenAccount) -> Void)?
    /// Called when a project was added, removed or changed, with the removed one's id; ``AppModel`` follows it with
    /// the Pipelines stores (PROJ-02).
    @ObservationIgnored public var projectsChanged: (@MainActor (ProjectID?) -> Void)?
    /// the projects, the primary one first, as Settings → Projects lists them (PROJ-02)
    public private(set) var projects: [Project] = []
    /// the primary project's team values, which the accounts, the welcome flow and GitLab's filters use
    public private(set) var primaryTeam: TeamValues

    private var storedPreferences: Preferences
    private var storedTeamDraft: TeamValues
    /// the saved team values
    public private(set) var team: TeamValues
    /// why the team values could not be saved; nil once they were
    public private(set) var teamError: String?
    /// the pane Settings shows; problem rows and links set it before they open Settings (SET-02). It is kept in
    /// UserDefaults (``selectedPaneKey``), so Settings opens at the pane it showed last, also after a restart.
    public var selectedPane: SettingsPane = .general {
        didSet {
            if selectedPane != oldValue {
                preferencesStore.userDefaults.set(selectedPane.rawValue, forKey: Self.selectedPaneKey)
            }
        }
    }
    /// what the import from jenkins-menubar did, which tells where the tokens came from (ACC-02)
    public var importReport: LegacyImportReport?
    /// the tokens in the keychain, as read last
    public private(set) var storedTokens: Set<TokenAccount> = []
    /// the Jenkins user of the stored token, for the User field (ACC-06)
    public private(set) var jenkinsUser = ""
    /// why a token could not be read, saved or removed, by account
    public private(set) var tokenErrors: [TokenAccount: String] = [:]
    /// whether the account check runs (ACC-04)
    public private(set) var isCheckingAccounts = false
    /// the results of the last account check, by account
    public private(set) var accounts: [TokenAccount: AccountStatus] = [:]
    /// the login item's status (APP-02)
    public private(set) var openAtLogin: LoginItemStatus
    /// why open at login could not be changed; nil once it could
    public private(set) var openAtLoginError: String?

    /// Creates the store from the stored preferences and team values. The tokens are read by ``loadTokens()``.
    ///
    /// - Parameters:
    ///   - preferences: the preferences in UserDefaults
    ///   - team: the projects and the team file
    ///   - tokens: the keychain's tokens; it logs saving and removing
    ///   - launchAtLogin: open at login; it logs the changes
    ///   - log: where the changes are logged
    ///   - transport: the transport of the account check for a project, usually a `RequestRecorder`
    ///   - timeouts: the time limits of the account check
    ///   - clock: the clock of the pause before the team values are saved
    ///   - checkNow: starts a Jenkins check and a GitLab load at once (ACC-06)
    ///   - setCheckInterval: reschedules the Jenkins check (SET-01)
    public init(
        preferences: PreferencesStore,
        team: TeamStore,
        tokens: TokenStore,
        launchAtLogin: LaunchAtLogin,
        log: ActivityLog?,
        transport: @escaping @Sendable (Project) -> any HTTPTransport,
        timeouts: Timeouts = .standard,
        clock: any Clock<Duration> = ContinuousClock(),
        checkNow: @escaping @Sendable () async -> Void,
        setCheckInterval: @escaping @Sendable (Duration) async -> Void
    ) {
        preferencesStore = preferences
        teamStore = team
        tokenStore = tokens
        self.launchAtLogin = launchAtLogin
        self.log = log
        self.transport = transport
        self.timeouts = timeouts
        self.clock = clock
        self.checkNow = checkNow
        self.setCheckInterval = setCheckInterval
        let project = team.primaryProject()
        projectID = project.id
        primaryID = project.id
        self.team = project.team
        primaryTeam = project.team
        storedTeamDraft = project.team
        projects = team.projects()
        storedPreferences = preferences.load()
        openAtLogin = launchAtLogin.status
        if let pane = preferences.userDefaults.string(forKey: Self.selectedPaneKey).flatMap(SettingsPane.init(rawValue:)) {
            selectedPane = pane
        }
    }

    /// Reads the preferences, the team values and the login item's status again, as after the import at launch. Edits
    /// of the team values that wait for typing to pause are dropped.
    public func reload() {
        teamSave?.cancel()
        teamSave = nil
        storedPreferences = preferencesStore.load()
        let project = teamStore.primaryProject()
        projectID = project.id
        primaryID = project.id
        team = project.team
        primaryTeam = project.team
        storedTeamDraft = project.team
        projects = teamStore.projects()
        openAtLogin = launchAtLogin.status
    }

    /// Waits until the changes made so far are saved, logged and have taken effect, the team values once typing
    /// paused too.
    public func waitUntilSettled() async {
        await teamSave?.value
        await work?.value
    }

    // MARK: - Preferences (SET-01)

    /// The saved preferences. Setting them saves the values that changed, logs each as "<key>: <old> → <new>", and
    /// applies them: a new interval reschedules the check. A value outside its options is saved as the default.
    public var preferences: Preferences {
        get { storedPreferences }
        set { apply(newValue, labelMessage: nil) }
    }

    /// Puts a label in one of the work item filters' lists, or in neither, and logs it with the text of WI-03.
    ///
    /// - Parameters:
    ///   - label: the label's title, kept as it is
    ///   - list: the list, or nil to take the label out of the filters
    public func setLabel(_ label: String, in list: WorkItemFilters.LabelList?) {
        var new = storedPreferences
        new.workItems.setLabel(label, in: list)
        apply(new, labelMessage: WorkItemFilters.message(label: label, putIn: list))
    }

    /// Sets whether a work item needs all or any of the must-have labels, and logs it with the text of WI-03.
    ///
    /// - Parameter match: all or any
    public func setLabelsMatch(_ match: WorkItemFilters.LabelsMatch) {
        var new = storedPreferences
        new.workItems.setLabelsMatch(match)
        apply(new, labelMessage: WorkItemFilters.message(labelsMatch: match))
    }

    /// Empties both label lists ("Clear All") and logs it with the text of WI-03.
    public func clearLabels() {
        var new = storedPreferences
        new.workItems.clearLabels()
        apply(new, labelMessage: WorkItemFilters.clearedLabelsMessage)
    }

    private func apply(_ new: Preferences, labelMessage: String?) {
        let changes = preferencesStore.save(new)
        guard !changes.isEmpty else { return }
        storedPreferences = preferencesStore.load()
        var messages = changes
            .filter { labelMessage == nil || !Self.labelKeys.contains($0.key) }
            .map { "\($0.key.rawValue): \(Self.shown($0.old)) → \(Self.shown($0.new))" }
        if let labelMessage, changes.contains(where: { Self.labelKeys.contains($0.key) }) {
            messages.append(labelMessage)
        }
        logInfo(messages)
        if changes.contains(where: { $0.key == .checkIntervalSeconds }) {
            let interval = Duration.seconds(storedPreferences.checkIntervalSeconds)
            let setCheckInterval = setCheckInterval
            enqueue { await setCheckInterval(interval) }
        }
        preferencesChanged?(storedPreferences)
    }

    // MARK: - Team (TEAM-01 to TEAM-03)

    /// The team values as the fields show them while they are edited. Setting them saves them once typing pauses for
    /// ``teamSaveDelay``: trimmed, the URLs without a trailing `/`, and only the values without a ``teamIssue(for:)``.
    public var teamDraft: TeamValues {
        get { storedTeamDraft }
        set {
            storedTeamDraft = newValue
            scheduleTeamSave()
        }
    }

    /// Returns what is wrong with a team value as it is entered.
    ///
    /// - Parameter key: the value
    /// - Returns: the text the field shows under it; nil when the value can be saved
    public func teamIssue(for key: TeamValues.Key) -> String? {
        Self.issue(of: storedTeamDraft[key], for: key)
    }

    /// the required team values that aren't saved yet; no request is made without them (TEAM-03)
    public var missingTeamValues: [TeamValues.Key] {
        primaryTeam.missing
    }

    /// whether the welcome flow opens at launch: it was never finished or closed, or the job URL, the GitLab URL or
    /// the project is missing (TEAM-03)
    public var needsWelcomeFlow: Bool {
        !preferencesStore.welcomeCompleted || !primaryTeam.missing.isEmpty
    }

    /// Records that the welcome flow was finished or closed, early too; from then on it opens at launch only while a
    /// required team value is missing (TEAM-03, IMP-03).
    public func completeWelcomeFlow() {
        preferencesStore.welcomeCompleted = true
    }

    /// Saves the team values the fields show now, without waiting for typing to pause, as when the pane closes.
    public func saveTeamNow() {
        teamSave?.cancel()
        teamSave = nil
        var next = team
        let draft = storedTeamDraft.normalized()
        for key in TeamValues.Key.allCases where Self.issue(of: draft[key], for: key) == nil {
            next[key] = draft[key]
        }
        do {
            try commitTeam(next)
        } catch {
            teamError = "The team values could not be saved: \(error.localizedDescription)"
        }
    }

    /// Reads a team file into Team and saves it (TEAM-02). Edits that wait for typing to pause are dropped.
    ///
    /// - Parameter url: the team file
    /// - Throws: a ``TeamFileError`` that says why the file was refused, or the error of saving
    public func importTeamFile(from url: URL) throws {
        let values = try TeamStore.readTeamFile(from: url)
        teamSave?.cancel()
        teamSave = nil
        try commitTeam(values, announcing: "Imported the team values from \(url.lastPathComponent)")
        storedTeamDraft = team
    }

    /// Writes the saved team values to a team file, without any token (TEAM-02). Edits that wait for typing to pause
    /// are saved first.
    ///
    /// - Parameter url: the file, which is replaced
    public func exportTeamFile(to url: URL) throws {
        saveTeamNow()
        try teamStore.exportTeamFile(of: projectID, to: url)
        logInfo(["Exported the team values to \(url.lastPathComponent)"])
    }

    private func scheduleTeamSave() {
        teamSave?.cancel()
        teamSave = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: Self.teamSaveDelay)
            } catch {
                return
            }
            self?.saveTeamNow()
        }
    }

    /// Saves the team values when they changed, logs each change, and starts a check with them.
    private func commitTeam(_ next: TeamValues, announcing announcement: String? = nil) throws {
        let changed = TeamValues.Key.allCases.filter { team[$0] != next[$0] }
        // Another project's values must stay complete and on the primary project's servers (PROJ-02).
        if !changed.isEmpty, projectID != primaryID,
           let refusal = ProjectError.refusal(of: next, among: projects.filter { $0.id != projectID }) {
            throw refusal
        }
        if !changed.isEmpty {
            try teamStore.save(Project(id: projectID, team: next))
        }
        teamError = nil
        let old = team
        team = next
        if projectID == primaryID {
            primaryTeam = next
        }
        // With several projects, the log names the one that changed.
        let prefix = projects.count > 1 ? "\(projectName(projectID)) " : ""
        let messages = changed.map { "\(prefix)Team \($0.rawValue): \(Self.shown(old[$0])) → \(Self.shown(next[$0]))" }
        logInfo((announcement.map { [$0] } ?? []) + messages)
        if !changed.isEmpty {
            projects = teamStore.projects()
            projectsChanged?(nil)
            let checkNow = checkNow
            enqueue { await checkNow() }
        }
    }

    // MARK: - Projects (PROJ-02)

    /// whether the edited project is the primary one, which can't be removed
    public var editsPrimaryProject: Bool {
        projectID == primaryID
    }

    /// Returns a project's name, as Settings → Projects lists it (PROJ-01).
    ///
    /// - Parameter id: the project
    /// - Returns: its name
    public func projectName(_ id: ProjectID) -> String {
        Project.names(of: projects)[id] ?? projects.first { $0.id == id }?.shortName ?? "Project"
    }

    /// Edits another project: what waits for typing to pause is saved first.
    ///
    /// - Parameter id: the project
    public func selectProject(_ id: ProjectID) {
        guard id != projectID, let project = teamStore.project(id) else {
            return
        }
        saveTeamNow()
        projectID = id
        team = project.team
        storedTeamDraft = project.team
        teamError = nil
    }

    /// Adds a project with complete values on the primary project's servers, edits it, and starts a check.
    ///
    /// - Parameter values: its team values
    /// - Throws: a ``ProjectError`` that says why it was refused, or the error of saving
    public func addProject(_ values: TeamValues) throws {
        saveTeamNow()
        let project = try teamStore.add(values)
        projects = teamStore.projects()
        logInfo(["Added the project \(projectName(project.id)): \(project.team.gitLabProject)"])
        projectsChanged?(nil)
        selectProject(project.id)
        let checkNow = checkNow
        enqueue { await checkNow() }
    }

    /// Adds a project from a team file (TEAM-02, PROJ-02).
    ///
    /// - Parameter url: the team file
    /// - Throws: a ``TeamFileError`` or a ``ProjectError`` that says why it was refused
    public func addProject(fromTeamFile url: URL) throws {
        try addProject(TeamStore.readTeamFile(from: url))
    }

    /// Removes a project that isn't the primary one; its watched and hidden builds and caches go too. The primary
    /// project is edited next.
    ///
    /// - Parameter id: the project
    /// - Throws: ``ProjectError/primary`` for the primary project, or the error of saving
    public func removeProject(_ id: ProjectID) throws {
        let name = projectName(id)
        if id == projectID {
            teamSave?.cancel()
            teamSave = nil
        }
        try teamStore.remove(id)
        projects = teamStore.projects()
        logInfo(["Removed the project \(name)"])
        if id == projectID {
            let primary = teamStore.primaryProject()
            projectID = primary.id
            team = primary.team
            storedTeamDraft = primary.team
            teamError = nil
        }
        projectsChanged?(id)
    }

    /// The check of TEAM-01: the URLs must be `http(s)` URLs with a host, the project a path with a `/`. An empty
    /// value is allowed; TEAM-03 asks for the required ones.
    static func issue(of value: String, for key: TeamValues.Key) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        switch key {
        case .jenkinsJobURL, .gitLabURL:
            return TeamValues(jenkinsJobURL: value).jenkinsJob == nil ? "Enter a URL that starts with https:// or http://" : nil
        case .gitLabProject:
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            let isPath = parts.count >= 2 && parts.allSatisfy { !$0.isEmpty } && !value.contains { $0.isWhitespace }
            return isPath ? nil : "Enter the project's path, like group/project"
        case .slotReleaseWeekday, .slotCodeFreezeWeekday, .slotEarlyAccessWeekday:
            return SlotRules.weekday(of: value) == nil ? "Enter a weekday, like Monday, or a number from 1 (Monday) to 7" : nil
        case .slotCodeFreezeNth, .slotEarlyAccessNth, .slotUpcomingShown:
            return SlotRules.nth(of: value) == nil ? "Enter a number from 1 to 12, like 4" : nil
        case .slotWarnDays:
            return SlotRules.days(of: value) == nil ? "Enter a number of days from 0 to 365" : nil
        case .slotPlanningURL:
            return TeamValues(slotPlanningURL: value).slotPlanning == nil ? "Enter a URL that starts with https:// or http://" : nil
        case .squadCapacity:
            return SquadCapacity(value) == nil ? "Enter points like Alpha: 60, Delta: 120, or one number for every squad" : nil
        case .committedLabel, .slotLabelPrefix, .ignoredMergeRequestPrefix, .typeLabelPrefix, .inProgressLabel, .slotGroup,
            .slotScheduledLabelPrefix, .squadLabelPrefix, .statusLabelPrefix:
            return nil
        }
    }

    // MARK: - Panes (SET-02)

    /// Chooses the pane that fixes a problem, before the app opens Settings.
    ///
    /// - Parameter problem: the problem of the row or link
    /// - Returns: whether a pane fixes it
    @discardableResult
    public func selectPane(for problem: Problem) -> Bool {
        guard let pane = SettingsPane.pane(for: problem) else { return false }
        selectedPane = pane
        return true
    }

    // MARK: - Tokens (ACC-05, ACC-06)

    /// Returns where a token comes from: the keychain, with where the import found it, or missing.
    ///
    /// - Parameter account: the token's account
    /// - Returns: the source
    public func tokenSource(_ account: TokenAccount) -> TokenSource {
        let outcome = enteredTokens.contains(account) ? nil : importReport?.token(account)
        if storedTokens.contains(account) {
            if case .imported(let source) = outcome {
                return .keychain(importedFrom: source)
            }
            return .keychain(importedFrom: nil)
        }
        switch outcome {
        case .notFound(let source), .notStored(let source, _): return .missing(source)
        default: return .missing(nil)
        }
    }

    /// Returns the link that creates a token, or nil while the team value it needs is missing (ACC-05).
    ///
    /// - Parameter account: the token's account
    /// - Returns: the link
    public func tokenLink(_ account: TokenAccount) -> TokenLink? {
        TokenLink.create(account, team: primaryTeam)
    }

    /// Returns whether Save is enabled for the Jenkins token: both fields hold something.
    public static func canSaveJenkinsToken(user: String, apiToken: String) -> Bool {
        !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns whether Save is enabled for the GitLab token: the field holds something.
    public static func canSaveGitLabToken(_ token: String) -> Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Reads which tokens the keychain holds, and the Jenkins user of the stored token.
    public func loadTokens() async {
        for account in TokenAccount.allCases {
            do {
                let token = try await tokenStore.token(account)
                let isStored = token?.isEmpty == false
                setStored(account, isStored)
                if account == .jenkins {
                    jenkinsUser = token.flatMap(TokenStore.jenkinsUser(fromToken:)) ?? jenkinsUser
                }
                tokenErrors[account] = nil
            } catch {
                tokenErrors[account] = error.localizedDescription
            }
        }
    }

    /// Saves the Jenkins token as base64 of `user:api-token`, both trimmed, then starts a check (ACC-06).
    ///
    /// - Parameters:
    ///   - user: the Jenkins user
    ///   - apiToken: the new API token
    /// - Returns: whether it was saved; ``tokenErrors`` says why not
    @discardableResult
    public func saveJenkinsToken(user: String, apiToken: String) async -> Bool {
        let apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        // base64 hides spaces and quotes, so the API token is checked on its own (ACC-03).
        guard Self.canSaveJenkinsToken(user: user, apiToken: apiToken), TokenStore.isValid(apiToken) else {
            tokenErrors[.jenkins] = TokenError.invalidFormat.localizedDescription
            return false
        }
        guard await store(TokenStore.jenkinsToken(user: user, apiToken: apiToken), for: .jenkins) else { return false }
        jenkinsUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        return true
    }

    /// Saves the GitLab token, trimmed, then starts a check (ACC-06).
    ///
    /// - Parameter token: the new token
    /// - Returns: whether it was saved; ``tokenErrors`` says why not
    @discardableResult
    public func saveGitLabToken(_ token: String) async -> Bool {
        await store(token, for: .gitlab)
    }

    /// Removes a token from the keychain, then starts a check (ACC-06).
    ///
    /// - Parameter account: the token's account
    public func removeToken(_ account: TokenAccount) async {
        await work?.value
        do {
            try await tokenStore.remove(account)
        } catch {
            tokenErrors[account] = error.localizedDescription
            return
        }
        tokenErrors[account] = nil
        accounts[account] = nil
        setStored(account, false)
        enteredTokens.insert(account)
        onTokenRemoved?(account)
        await checkNow()
    }

    private func store(_ token: String, for account: TokenAccount) async -> Bool {
        // The token store logs on its own, after the changes made before.
        await work?.value
        do {
            try await tokenStore.store(token, for: account)
        } catch {
            tokenErrors[account] = error.localizedDescription
            return false
        }
        tokenErrors[account] = nil
        // An earlier "Signed in as" no longer says anything about the new token.
        accounts[account] = nil
        setStored(account, true)
        enteredTokens.insert(account)
        guard accountViews > 0 else {
            await checkNow()
            return true
        }
        // ACC-04: while the account check shows, it runs by itself after a save, beside the check of ACC-06.
        let checkNow = checkNow
        async let checked: Void = checkNow()
        if isCheckingAccounts {
            // The check under way read the token before it was saved.
            checksAccountsAgain = true
        } else {
            await checkAccounts()
        }
        await checked
        return true
    }

    private func setStored(_ account: TokenAccount, _ isStored: Bool) {
        if isStored {
            storedTokens.insert(account)
        } else {
            storedTokens.remove(account)
        }
    }

    // MARK: - Account check (ACC-04)

    /// Notes that a view of the account check shows: Settings → Accounts or the welcome flow's Accounts step. The
    /// first showing in a session with a token stored runs the check by itself, and while one shows, saving a token
    /// runs it too; Check runs it again (ACC-04). Call ``accountsDisappeared()`` when the view goes.
    public func accountsAppeared() async {
        accountViews += 1
        guard !hasCheckedAccounts, !storedTokens.isEmpty else { return }
        await checkAccounts()
    }

    /// Notes that a view of the account check went away (``accountsAppeared()``).
    public func accountsDisappeared() {
        accountViews = max(0, accountViews - 1)
    }

    /// Asks Jenkins for the job and GitLab for the current user with the stored tokens, and logs each answer:
    /// "Account check: Signed in as jdoe". Without the team value or the token, it asks nothing and says so. Edits of
    /// the team values that wait for typing to pause are saved first.
    public func checkAccounts() async {
        guard !isCheckingAccounts else { return }
        hasCheckedAccounts = true
        saveTeamNow()
        isCheckingAccounts = true
        var results: [(TokenAccount, AccountStatus)]
        repeat {
            checksAccountsAgain = false
            let project = Project(id: primaryID, team: primaryTeam)
            let transport = self.transport(project)
            async let jenkins = Self.checkJenkins(project: project, tokens: tokenStore, transport: transport, timeouts: timeouts)
            async let gitLab = Self.checkGitLab(team: project.team, tokens: tokenStore, transport: transport, timeouts: timeouts)
            results = await [(TokenAccount.jenkins, jenkins), (.gitlab, gitLab)]
        } while checksAccountsAgain
        isCheckingAccounts = false
        for (account, status) in results {
            accounts[account] = status
            let source: ActivityEntry.Source = account == .jenkins ? .jenkins : .gitlab
            let message = "Account check: \(status.message)"
            let log = log
            enqueue {
                if status.ok {
                    await log?.log(.info, source, message, outcome: .ok("OK"))
                } else {
                    await log?.log(.warning, source, message, outcome: .failed("FAILED"))
                }
            }
        }
    }

    @concurrent
    private nonisolated static func checkJenkins(
        project: Project, tokens: TokenStore, transport: any HTTPTransport, timeouts: Timeouts
    ) async -> AccountStatus {
        guard project.team.jenkinsJob != nil else { return .noJenkinsJob }
        let token: String?
        do {
            token = try await tokens.token(.jenkins)
        } catch {
            return AccountStatus(ok: false, message: error.localizedDescription)
        }
        switch JenkinsClient.make(project: project, token: token, transport: transport, timeouts: timeouts) {
        case .failure(let error):
            return error.problem == .teamValuesMissing ? .noJenkinsJob : .noToken
        case .success(let client):
            do {
                // A token that isn't base64 of user:token still works when Jenkins takes it; it just names no one.
                return try await client.account().map(AccountStatus.signedIn(as:)) ?? AccountStatus(ok: true, message: "Jenkins accepts the token")
            } catch let error as JenkinsError {
                return AccountStatus(ok: false, message: error.problem.message)
            } catch {
                return AccountStatus(ok: false, message: error.localizedDescription)
            }
        }
    }

    @concurrent
    private nonisolated static func checkGitLab(
        team: TeamValues, tokens: TokenStore, transport: any HTTPTransport, timeouts: Timeouts
    ) async -> AccountStatus {
        guard let gitLab = team.gitLab else { return .noGitLabURL }
        let token: String?
        do {
            token = try await tokens.token(.gitlab)
        } catch {
            return AccountStatus(ok: false, message: error.localizedDescription)
        }
        guard let token, !token.isEmpty else { return .noToken }
        do {
            let client = GitLabClient(transport: transport, gitLab: gitLab, token: token, timeouts: timeouts)
            let username = try await client.send(.currentUser)
            // A token that can't say what it may do isn't blamed: only a known read-only one is noted (MR-09).
            let access = (try? await client.tokenScopes()).map(WriteAccess.init(scopes:))
            return .signedIn(as: username, readOnly: access == .readOnly)
        } catch let error as GitLabError {
            return AccountStatus(ok: false, message: error.problem.message)
        } catch {
            return AccountStatus(ok: false, message: error.localizedDescription)
        }
    }

    // MARK: - Open at login (APP-02)

    /// Turns open at login on or off. The login item's status afterwards is the truth; it may wait for approval.
    ///
    /// - Parameter on: whether the app opens at login
    public func setOpenAtLogin(_ on: Bool) async {
        await work?.value
        do {
            openAtLogin = try await launchAtLogin.setOn(on)
            openAtLoginError = nil
        } catch {
            openAtLogin = launchAtLogin.status
            openAtLoginError = (error as? LoginItemError)?.message ?? error.localizedDescription
        }
    }

    /// Reads the login item's status again; System Settings can change it at any time.
    public func refreshOpenAtLogin() {
        openAtLogin = launchAtLogin.status
    }

    /// Opens System Settings → General → Login Items, where the user approves the login item.
    public func openLoginItemsSettings() {
        launchAtLogin.openSystemSettings()
    }

    // MARK: - Logging

    private func logInfo(_ messages: [String]) {
        guard !messages.isEmpty, let log else { return }
        enqueue {
            for message in messages {
                await log.log(.info, .settings, message)
            }
        }
    }

    private func enqueue(_ job: @escaping @Sendable () async -> Void) {
        let previous = work
        work = Task {
            await previous?.value
            await job()
        }
    }

    /// "(empty)" for an empty value, as the log shows it (SET-01, TEAM-01).
    private static func shown(_ value: String) -> String {
        value.isEmpty ? "(empty)" : value
    }
}
