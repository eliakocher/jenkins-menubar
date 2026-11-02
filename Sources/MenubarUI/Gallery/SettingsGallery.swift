#if DEBUG
import MenubarCore
import SwiftUI

/// A pane's form at its size, as the Settings window shows it under the pane toolbar (`docs/design/settings.md`,
/// States): the gallery's ordinary window would draw a `TabView` as classic tabs, so the toolbar is a manual check.
/// The form measures its height as in the window, and the gallery's window fits it, so a shot shows the whole state
/// (review SETTINGS-02); the entry's height is only the first estimate.
private struct SettingsPaneGalleryView<Content: View>: View {
    let height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .settingsPaneFrame(estimate: height)
    }
}

/// Settings → General with fixed values.
private struct GeneralGalleryView: View {
    var preferences = Preferences()
    var login = LoginItemStatus.notRegistered
    var loginError: String?
    var hotkey = HotkeyStatus.off
    var isRecordingShortcut = false

    var body: some View {
        GeneralSettingsForm(
            preferences: .constant(preferences), openAtLogin: .constant(login.isOn), loginStatus: login,
            loginError: loginError, hotkey: hotkey, isRecordingShortcut: isRecordingShortcut, actions: .none,
            linkRouting: LinkRoutingSwitch(isOn: .constant(false), browserName: "Safari", note: nil, isChanging: false))
    }
}

/// Settings → Notifications with fixed values.
private struct NotificationsGalleryView: View {
    var preferences = Preferences()
    var permission = NotificationPermission.allowed
    var canPreview = true
    var policy = NotificationPolicy()

    var body: some View {
        NotificationsSettingsForm(
            preferences: .constant(preferences), notification: NotificationNotice.of(permission, preferences: preferences),
            canPreview: canPreview, actions: .none, policy: policy)
    }
}

/// Settings → GitLab with fixed filters; no picker shows.
private struct GitLabGalleryView: View {
    let preferences: Preferences
    var missing: [String] = []
    let colors: [String: String]

    var body: some View {
        GitLabSettingsForm(
            preferences: .constant(preferences), missingLabels: missing, colors: colors, actions: .none,
            pickerList: .constant(nil)
        ) { _ in
            EmptyView()
        }
    }
}

/// The label picker's content alone, at its popover's size.
private struct LabelPickerGalleryView: View {
    var list = WorkItemFilters.LabelList.with
    let filters: WorkItemFilters
    var query = ""
    let result: LabelSearchResult
    var isSearching = false
    let colors: [String: String]

    var body: some View {
        LabelPickerContent(
            list: list, filters: filters, query: .constant(query), result: result, isSearching: isSearching,
            colors: colors, project: "group/subgroup/project", toggle: { _ in }, done: {})
    }
}

/// Settings → Team with fixed values, issues and results.
private struct TeamGalleryView: View {
    let values: TeamValues
    var issues: [TeamValues.Key: String] = [:]
    var problems: [String] = []
    var fileResult: TeamFileResult?

    var body: some View {
        TeamSettingsForm(
            values: .constant(values), issues: issues, problems: problems, fileResult: fileResult,
            canExport: values != TeamValues())
    }
}

/// Settings → Projects with fixed values; one project unless the entry gives more.
private struct ProjectsGalleryView: View {
    let values: TeamValues
    var issues: [TeamValues.Key: String] = [:]
    var problems: [String] = []
    var projects: [ProjectRow]?
    var selected: ProjectID = .main

    var body: some View {
        let single = ProjectRow(id: .main, name: Project(id: .main, team: values).shortName, path: values.gitLabProject)
        ProjectsSettingsForm(
            values: .constant(values), issues: issues, problems: problems, projects: projects ?? [single],
            selected: selected)
    }
}

/// Settings → Accounts with fixed values; the token fields show what is typed in them.
private struct AccountsGalleryView: View {
    let model: AccountsFormModel
    var gitLabURL = "https://gitlab.example.com"
    var server: String? = "jenkins.example.com"
    var user = "jdoe"
    var jenkinsToken = ""
    var gitLabToken = ""

    var body: some View {
        var model = model
        model.jenkinsServer = server
        return AccountsSettingsForm(
            model: model, gitLabURL: .constant(gitLabURL), jenkinsUser: .constant(user),
            jenkinsToken: .constant(jenkinsToken), gitLabToken: .constant(gitLabToken), actions: .none)
    }
}

/// The whole Settings window at one pane, with fixed values, as the window opens.
private struct SettingsWindowGalleryView: View {
    let fixtures: Fixtures
    @ViewState var pane: SettingsPane
    @ViewState var query: String

    init(fixtures: Fixtures, pane: SettingsPane, query: String = "") {
        self.fixtures = fixtures
        _pane = ViewState(initialValue: pane)
        _query = ViewState(initialValue: query)
    }

    var body: some View {
        SettingsShell(selection: $pane, query: $query) { pane in
            switch pane {
            case .general: GeneralGalleryView()
            case .notifications: NotificationsGalleryView()
            case .appearance: AppearanceSettingsForm()
            case .accounts:
                AccountsGalleryView(model: {
                    var model = fixtures.settingsAccounts
                    model.results = fixtures.settingsSignedIn
                    return model
                }())
            case .projects: ProjectsGalleryView(values: fixtures.team)
            case .team: TeamGalleryView(values: fixtures.team)
            case .pipelines: JenkinsSettingsForm(preferences: .constant(Preferences()))
            case .workItems: GitLabGalleryView(preferences: Preferences(), colors: fixtures.settingsLabelColors)
            case .workspaces: Text("Workspaces: see settings-repositories")
            case .claude: ClaudePane()
            case .advanced: AdvancedSettingsForm(preferences: .constant(Preferences()), canShowWelcome: true)
            }
        }
    }
}

extension GalleryCatalog {
    /// One entry per state of the five Settings pane specs, `docs/design/settings-<pane>.md`; the heights are the
    /// specs' estimates, and the windows then fit the forms' measured heights.
    static var settingsEntries: [GalleryEntry] {
        settingsWindowEntries + settingsGeneralEntries + settingsJenkinsEntries + settingsGitLabEntries
            + settingsTeamEntries + settingsTeamLinkEntries + settingsProjectsEntries + settingsAccountsEntries + settingsAdvancedEntries
    }

    // MARK: - Window

    private static var settingsWindowEntries: [GalleryEntry] {
        SettingsPane.allCases.map { pane in
            GalleryEntry(screen: "settings-window", state: pane.rawValue, size: SettingsMetrics.window) { f in
                SettingsWindowGalleryView(fixtures: f, pane: pane)
            }
        } + [
            GalleryEntry(screen: "settings-window", state: "search", size: SettingsMetrics.window) { f in
                SettingsWindowGalleryView(fixtures: f, pane: .team, query: "freeze")
            },
            GalleryEntry(screen: "settings-window", state: "search-field", size: SettingsMetrics.window) { f in
                SettingsWindowGalleryView(fixtures: f, pane: .accounts, query: "token")
            },
        ]
    }

    private static func paneSize(_ height: CGFloat) -> CGSize {
        CGSize(width: SettingsMetrics.width, height: height)
    }

    // MARK: - General

    private static var settingsGeneralEntries: [GalleryEntry] {
        var changed = Preferences()
        changed.showInMenuBar = false
        changed.iconStyle = .color
        changed.alertStyle = .banner
        changed.stageAlerts = false
        changed.fillInCopiedLink = true
        var banner = Preferences()
        banner.alertStyle = .banner
        let shortcut = HotkeyShortcut(keyCode: 40, modifiers: [.control, .option, .command], label: "K")
        let withShortcut = Preferences(globalShortcut: shortcut)
        return [
            GalleryEntry(screen: "settings-general", state: "typical", size: paneSize(380)) { _ in
                SettingsPaneGalleryView(height: 380) { GeneralGalleryView() }
            },
            GalleryEntry(screen: "settings-general", state: "shortcut", size: paneSize(410)) { _ in
                SettingsPaneGalleryView(height: 410) {
                    GeneralGalleryView(preferences: withShortcut, hotkey: shortcut.map { .active($0) } ?? .off)
                }
            },
            GalleryEntry(screen: "settings-general", state: "shortcut-recording", size: paneSize(410)) { _ in
                SettingsPaneGalleryView(height: 410) { GeneralGalleryView(isRecordingShortcut: true) }
            },
            GalleryEntry(screen: "settings-general", state: "shortcut-taken", size: paneSize(440)) { _ in
                SettingsPaneGalleryView(height: 440) {
                    GeneralGalleryView(
                        preferences: withShortcut, hotkey: shortcut.map { .failed($0, .taken) } ?? .off)
                }
            },
            GalleryEntry(screen: "settings-general", state: "changed", size: paneSize(380)) { _ in
                SettingsPaneGalleryView(height: 380) { GeneralGalleryView(preferences: changed, login: .enabled) }
            },
            GalleryEntry(screen: "settings-general", state: "login-approval", size: paneSize(430)) { _ in
                SettingsPaneGalleryView(height: 430) { GeneralGalleryView(login: .requiresApproval) }
            },
            GalleryEntry(screen: "settings-general", state: "login-not-found", size: paneSize(420)) { _ in
                SettingsPaneGalleryView(height: 420) { GeneralGalleryView(login: .notFound) }
            },
            GalleryEntry(screen: "settings-general", state: "login-error", size: paneSize(450)) { _ in
                SettingsPaneGalleryView(height: 450) {
                    GeneralGalleryView(loginError: LoginItemError(
                        turningOn: true,
                        reason: "The operation couldn’t be completed. Operation not permitted by the background task "
                            + "management policy of this Mac").message)
                }
            },
            GalleryEntry(screen: "settings-notifications", state: "typical", size: paneSize(360)) { _ in
                SettingsPaneGalleryView(height: 360) { NotificationsGalleryView() }
            },
            GalleryEntry(screen: "settings-notifications", state: "muted-jobs", size: paneSize(560)) { _ in
                SettingsPaneGalleryView(height: 560) {
                    NotificationsGalleryView(policy: NotificationPolicy(
                        mine: true, watching: false, jobs: ["MR-1412": .never, "develop": .always, "release%2F2026.51": .never]))
                }
            },
            GalleryEntry(screen: "settings-notifications", state: "off", size: paneSize(400)) { _ in
                SettingsPaneGalleryView(height: 400) { NotificationsGalleryView(preferences: banner, permission: .off) }
            },
            GalleryEntry(screen: "settings-notifications", state: "not-set-up", size: paneSize(400)) { _ in
                SettingsPaneGalleryView(height: 400) { NotificationsGalleryView(permission: .notAsked) }
            },
            GalleryEntry(screen: "settings-notifications", state: "no-team-values", size: paneSize(360)) { _ in
                SettingsPaneGalleryView(height: 360) { NotificationsGalleryView(canPreview: false) }
            },
        ]
    }

    // MARK: - Jenkins

    private static var settingsJenkinsEntries: [GalleryEntry] {
        var changed = Preferences()
        changed.checkIntervalSeconds = 30
        changed.hideSuccessfulAfter = .immediately
        changed.hideFailedAfter = .never
        changed.hidesMergedBuilds = false
        return [
            GalleryEntry(screen: "settings-jenkins", state: "typical", size: paneSize(300)) { _ in
                SettingsPaneGalleryView(height: 300) { JenkinsSettingsForm(preferences: .constant(Preferences())) }
            },
            GalleryEntry(screen: "settings-jenkins", state: "changed", size: paneSize(300)) { _ in
                SettingsPaneGalleryView(height: 300) { JenkinsSettingsForm(preferences: .constant(changed)) }
            },
        ]
    }

    // MARK: - Advanced

    private static var settingsAdvancedEntries: [GalleryEntry] {
        [
            GalleryEntry(screen: "settings-advanced", state: "typical", size: paneSize(440)) { _ in
                SettingsPaneGalleryView(height: 440) {
                    AdvancedSettingsForm(preferences: .constant(Preferences()), canShowWelcome: true)
                }
            },
            GalleryEntry(screen: "settings-advanced", state: "imported", size: paneSize(440)) { _ in
                SettingsPaneGalleryView(height: 440) {
                    AdvancedSettingsForm(
                        preferences: .constant(Preferences()),
                        backupResult: TeamFileResult(kind: .ok, text: "Imported 31 values from megamonitor-settings.json"),
                        canShowWelcome: true)
                }
            },
            GalleryEntry(screen: "settings-advanced", state: "refused", size: paneSize(440)) { _ in
                SettingsPaneGalleryView(height: 440) {
                    AdvancedSettingsForm(
                        preferences: .constant(Preferences()),
                        backupResult: TeamFileResult(
                            kind: .problem, text: PersonalSettingsBackupError.newerFormat(2).message),
                        canShowWelcome: false)
                }
            },
        ]
    }

    // MARK: - GitLab

    private static var settingsGitLabEntries: [GalleryEntry] {
        let pickerSize = LabelPickerContent.size
        let filtersSet = WorkItemFilters(
            scope: .authored, type: .issue, state: .all, sort: .dueDate, limit: 50,
            withLabels: ["priority::high", "frontend"], withoutLabels: ["wontfix"])
        let anyMode = WorkItemFilters(withLabels: ["team::web::frontend", "team::web::backend"], labelsMatch: .any)
        let gone = WorkItemFilters(withLabels: ["priority::high", "workflow::gone"])
        let many = WorkItemFilters(withLabels: [
            "priority::high", "frontend", "design", "docs", "team::web::frontend", "workflow::in-progress", "type::bug",
            "release", "needs-review", "type::feature", "priority::low", "workflow::committed",
        ], labelsMatch: .any)
        let long = WorkItemFilters(
            withLabels: [
                "team::platform::a-very-long-label-name-for-the-search-index-rework",
                "workflow::waiting-for-the-review-of-the-search-index-rework",
                // Wider than the row, so the pill is cut in the middle (review SETTINGS-GITLAB-02).
                "release::a-label-value-of-about-ninety-characters-that-is-wider-than-the-row-left-of-add-label",
            ],
            withoutLabels: ["a-very-long-label-without-a-scope-for-the-search-index-rework"])
        let pickerFilters = WorkItemFilters(withLabels: ["priority::high"], withoutLabels: ["wontfix"])
        return [
            GalleryEntry(screen: "settings-gitlab", state: "typical", size: paneSize(560)) { f in
                SettingsPaneGalleryView(height: 560) {
                    GitLabGalleryView(preferences: Preferences(), colors: f.settingsLabelColors)
                }
            },
            GalleryEntry(screen: "settings-gitlab", state: "filters-set", size: paneSize(600)) { f in
                SettingsPaneGalleryView(height: 600) {
                    GitLabGalleryView(preferences: f.settingsPreferences(filtersSet), colors: f.settingsLabelColors)
                }
            },
            GalleryEntry(screen: "settings-gitlab", state: "any-mode", size: paneSize(600)) { f in
                SettingsPaneGalleryView(height: 600) {
                    GitLabGalleryView(preferences: f.settingsPreferences(anyMode), colors: f.settingsLabelColors)
                }
            },
            GalleryEntry(screen: "settings-gitlab", state: "gone-label", size: paneSize(640)) { f in
                SettingsPaneGalleryView(height: 640) {
                    GitLabGalleryView(
                        preferences: f.settingsPreferences(gone), missing: ["workflow::gone"], colors: f.settingsLabelColors)
                }
            },
            GalleryEntry(screen: "settings-gitlab", state: "many-labels", size: paneSize(660)) { f in
                SettingsPaneGalleryView(height: 660) {
                    GitLabGalleryView(preferences: f.settingsPreferences(many), colors: f.settingsLabelColors)
                }
            },
            GalleryEntry(screen: "settings-gitlab", state: "long-labels", size: paneSize(620)) { f in
                SettingsPaneGalleryView(height: 620) {
                    GitLabGalleryView(preferences: f.settingsPreferences(long), colors: f.settingsLabelColors)
                }
            },
            GalleryEntry(screen: "settings-gitlab", state: "picker-known", size: pickerSize) { f in
                LabelPickerGalleryView(
                    filters: pickerFilters, result: f.settingsSearch(f.settingsKnownLabels), colors: f.settingsLabelColors)
            },
            GalleryEntry(screen: "settings-gitlab", state: "picker-search", size: pickerSize) { f in
                LabelPickerGalleryView(
                    filters: pickerFilters, query: "front", result: f.settingsSearch(["frontend", "team::web::frontend"]),
                    colors: f.settingsLabelColors)
            },
            GalleryEntry(screen: "settings-gitlab", state: "picker-searching", size: pickerSize) { f in
                LabelPickerGalleryView(
                    filters: pickerFilters, query: "prio", result: f.settingsSearch(["priority::high", "priority::low"]),
                    isSearching: true, colors: f.settingsLabelColors)
            },
            GalleryEntry(screen: "settings-gitlab", state: "picker-no-results", size: pickerSize) { f in
                LabelPickerGalleryView(
                    filters: pickerFilters, query: "zzz", result: f.settingsSearch([]), colors: f.settingsLabelColors)
            },
            GalleryEntry(screen: "settings-gitlab", state: "picker-empty", size: pickerSize) { f in
                LabelPickerGalleryView(filters: WorkItemFilters(), result: f.settingsSearch([]), colors: [:])
            },
            GalleryEntry(screen: "settings-gitlab", state: "picker-no-token", size: pickerSize) { f in
                LabelPickerGalleryView(
                    filters: pickerFilters, query: "work",
                    result: f.settingsSearch(["workflow::committed", "workflow::in-progress"], problem: LabelSearchResult.noTokenProblem),
                    colors: f.settingsLabelColors)
            },
            GalleryEntry(screen: "settings-gitlab", state: "picker-no-answer", size: pickerSize) { f in
                LabelPickerGalleryView(
                    filters: pickerFilters, query: "work",
                    result: f.settingsSearch(["workflow::committed", "workflow::in-progress"], problem: LabelSearchResult.noAnswerProblem),
                    colors: f.settingsLabelColors)
            },
        ]
    }

    // MARK: - Team

    private static var settingsTeamEntries: [GalleryEntry] {
        [
            GalleryEntry(screen: "settings-team", state: "typical", size: paneSize(900)) { f in
                SettingsPaneGalleryView(height: 900) { TeamGalleryView(values: f.team) }
            },
            GalleryEntry(screen: "settings-team", state: "empty", size: paneSize(900)) { _ in
                SettingsPaneGalleryView(height: 900) { TeamGalleryView(values: TeamValues()) }
            },
            GalleryEntry(screen: "settings-team", state: "invalid", size: paneSize(940)) { f in
                var draft = f.team
                draft.slotPlanningURL = "planning.example.com"
                draft.squadCapacity = "Alpha sixty"
                draft.slotWarnDays = "soon"
                return SettingsPaneGalleryView(height: 940) {
                    TeamGalleryView(values: draft, issues: [
                        .slotPlanningURL: "Enter a URL that starts with https:// or http://",
                        .squadCapacity: "Enter points like Alpha: 60, Delta: 120, or one number for every squad",
                        .slotWarnDays: "Enter a number of days from 0 to 365",
                    ])
                }
            },
            GalleryEntry(screen: "settings-team", state: "imported", size: paneSize(900)) { f in
                SettingsPaneGalleryView(height: 900) {
                    TeamGalleryView(
                        values: f.team, fileResult: TeamFileResult(kind: .ok, text: "Imported the team values from team.json"))
                }
            },
            GalleryEntry(screen: "settings-team", state: "import-error", size: paneSize(900)) { f in
                SettingsPaneGalleryView(height: 900) {
                    TeamGalleryView(
                        values: f.team, fileResult: TeamFileResult(kind: .problem, text: TeamFileError.newerFormat(2).message))
                }
            },
            GalleryEntry(screen: "settings-team", state: "save-error", size: paneSize(940)) { f in
                SettingsPaneGalleryView(height: 940) {
                    TeamGalleryView(values: f.team, problems: [
                        "The team values could not be saved: You don’t have permission to save the file “team.json” in "
                            + "the folder “\(AppIdentity.name)”.",
                    ])
                }
            },
        ]
    }

    // MARK: - Team file from a link

    /// Import from a Link…'s sheet in its stages, from fixed values.
    private static var settingsTeamLinkEntries: [GalleryEntry] {
        let link = "https://gitlab.example.com/group/project/-/raw/main/team.json"
        let current = TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: "https://gitlab.example.com",
            gitLabProject: "group/project", committedLabel: "committed", slotLabelPrefix: "slot::")
        var changed = current
        changed.committedLabel = "planning::committed"
        changed.slotLabelPrefix = ""
        changed.slotGroup = "group"
        changed.squadCapacity = "Alpha: 60, Bravo: 120, Charlie: 90, Delta: 75, Echo: 100, Foxtrot: 110, Golf: 80"
        changed.slotPlanningURL = "https://planning.example.com/a/very/long/path/to/the/team/planning/page"
        var moved = changed
        moved.gitLabURL = "https://gitlab.example.org"
        moved.jenkinsJobURL = "https://ci.example.org/job/project"
        let plain = TeamFileImport.Preview(current: current, incoming: changed)
        let hosts = TeamFileImport.Preview(current: current, incoming: moved)
        let same = TeamFileImport.Preview(current: current, incoming: current)
        func entry(
            _ state: String, isFetching: Bool = false, error: String? = nil, preview: TeamFileImport.Preview? = nil
        ) -> GalleryEntry {
            let height = TeamFileLinkContent.height(preview: preview)
            return GalleryEntry(screen: "settings-team-link", state: state, size: CGSize(width: 560, height: height)) { _ in
                TeamFileLinkContent(
                    link: .constant(link), isFetching: isFetching, error: error, preview: preview,
                    source: preview == nil ? nil : "gitlab.example.com", confirmed: .constant([]))
            }
        }
        return [
            entry("link"),
            entry("fetching", isFetching: true),
            entry("error", error: TeamFileImport.FetchError.status(404).message),
            entry("preview", preview: plain),
            entry("host-change", preview: hosts),
            entry("nothing-changes", preview: same),
        ]
    }

    // MARK: - Projects

    private static var settingsProjectsEntries: [GalleryEntry] {
        [
            GalleryEntry(screen: "settings-projects", state: "typical", size: paneSize(360)) { f in
                SettingsPaneGalleryView(height: 360) { ProjectsGalleryView(values: f.team) }
            },
            GalleryEntry(screen: "settings-projects", state: "empty", size: paneSize(400)) { _ in
                SettingsPaneGalleryView(height: 400) {
                    ProjectsGalleryView(values: TeamValues(), problems: [Problem.teamValuesMissing.message])
                }
            },
            GalleryEntry(screen: "settings-projects", state: "invalid", size: paneSize(420)) { f in
                var draft = f.team
                draft.jenkinsJobURL = "jenkins.example.com/job/project"
                draft.gitLabProject = "project"
                return SettingsPaneGalleryView(height: 420) {
                    ProjectsGalleryView(values: draft, issues: [
                        .jenkinsJobURL: "Enter a URL that starts with https:// or http://",
                        .gitLabProject: "Enter the project's path, like group/project",
                    ])
                }
            },
            GalleryEntry(screen: "settings-projects", state: "unknown-job", size: paneSize(400)) { f in
                SettingsPaneGalleryView(height: 400) {
                    ProjectsGalleryView(values: f.team, problems: [Problem.unknownJob.message])
                }
            },
            GalleryEntry(screen: "settings-projects", state: "several", size: paneSize(460)) { f in
                // Three projects, the second one edited (plan Phase 13).
                var values = f.team
                values.gitLabProject = "group/subgroup/client"
                values.jenkinsJobURL = "https://jenkins.example.com/job/GitLab%20Team/job/group%252Fsubgroup%252Fclient"
                let client = ProjectID(rawValue: "p-client")!
                let rows = [
                    ProjectRow(id: .main, name: "project", path: f.team.gitLabProject),
                    ProjectRow(id: client, name: "client", path: values.gitLabProject),
                    ProjectRow(id: ProjectID(rawValue: "p-docs")!, name: "docs", path: "group/docs"),
                ]
                return SettingsPaneGalleryView(height: 460) {
                    ProjectsGalleryView(values: values, projects: rows, selected: client)
                }
            },
            GalleryEntry(screen: "settings-projects", state: "add-project", size: CGSize(width: 560, height: 300)) { _ in
                AddProjectSheet(
                    values: .constant(TeamValues(
                        jenkinsJobURL: "https://ci.example.org/job/client", gitLabURL: "https://gitlab.example.com",
                        gitLabProject: "group/client")),
                    error: ProjectError.otherJenkins("project").message)
            },
            GalleryEntry(screen: "settings-projects", state: "long-values", size: paneSize(380)) { f in
                var values = f.team
                values.jenkinsJobURL = "https://jenkins.example.com/job/a-very-long-folder-name/job/another-folder/job/"
                    + "the-multibranch-project-for-the-search-index"
                values.gitLabProject = "group/subgroup/a-very-long-project-name-for-the-search-index-rework"
                return SettingsPaneGalleryView(height: 380) { ProjectsGalleryView(values: values) }
            },
        ]
    }

    // MARK: - Accounts

    private static var settingsAccountsEntries: [GalleryEntry] {
        [
            GalleryEntry(screen: "settings-accounts", state: "typical", size: paneSize(560)) { f in
                var model = f.settingsAccounts
                model.results = f.settingsSignedIn
                return SettingsPaneGalleryView(height: 560) { AccountsGalleryView(model: model) }
            },
            GalleryEntry(screen: "settings-accounts", state: "empty", size: paneSize(520)) { f in
                var model = f.settingsAccounts
                model.jenkinsSource = .missing(nil)
                model.gitLabSource = .missing(nil)
                return SettingsPaneGalleryView(height: 520) { AccountsGalleryView(model: model, user: "") }
            },
            GalleryEntry(screen: "settings-accounts", state: "imported", size: paneSize(560)) { f in
                var model = f.settingsAccounts
                model.jenkinsSource = .keychain(importedFrom: .zshrc)
                model.gitLabSource = .keychain(importedFrom: .oldKeychain)
                model.results = f.settingsSignedIn
                return SettingsPaneGalleryView(height: 560) { AccountsGalleryView(model: model) }
            },
            GalleryEntry(screen: "settings-accounts", state: "zshrc-computed", size: paneSize(540)) { f in
                var model = f.settingsAccounts
                model.gitLabSource = .missing(.zshrcComputed)
                return SettingsPaneGalleryView(height: 540) { AccountsGalleryView(model: model) }
            },
            GalleryEntry(screen: "settings-accounts", state: "no-team-values", size: paneSize(520)) { f in
                var model = f.settingsAccounts
                model.jenkinsLink = nil
                model.gitLabLink = nil
                model.results = [.jenkins: .noJenkinsJob, .gitlab: .noGitLabURL]
                return SettingsPaneGalleryView(height: 520) { AccountsGalleryView(model: model, gitLabURL: "", server: nil) }
            },
            GalleryEntry(screen: "settings-accounts", state: "checking", size: paneSize(500)) { f in
                var model = f.settingsAccounts
                model.isChecking = true
                return SettingsPaneGalleryView(height: 500) { AccountsGalleryView(model: model) }
            },
            GalleryEntry(screen: "settings-accounts", state: "check-problems", size: paneSize(560)) { f in
                var model = f.settingsAccounts
                model.results = [
                    .jenkins: AccountStatus(ok: false, message: Problem.rejectedToken(.jenkins).message),
                    .gitlab: AccountStatus(ok: false, message: Problem.unreachable(.gitLab).message),
                ]
                return SettingsPaneGalleryView(height: 560) { AccountsGalleryView(model: model) }
            },
            GalleryEntry(screen: "settings-accounts", state: "jenkins-accepts", size: paneSize(560)) { f in
                var model = f.settingsAccounts
                model.results = [.jenkins: AccountStatus(ok: true, message: "Jenkins accepts the token"), .gitlab: .signedIn(as: f.me)]
                return SettingsPaneGalleryView(height: 560) { AccountsGalleryView(model: model, user: "") }
            },
            GalleryEntry(screen: "settings-accounts", state: "rejected-token", size: paneSize(590)) { f in
                var model = f.settingsAccounts
                model.problems = [Problem.rejectedToken(.jenkins).message]
                model.results = [
                    .jenkins: AccountStatus(ok: false, message: Problem.rejectedToken(.jenkins).message),
                    .gitlab: .signedIn(as: f.me),
                ]
                return SettingsPaneGalleryView(height: 590) { AccountsGalleryView(model: model) }
            },
            GalleryEntry(screen: "settings-accounts", state: "invalid-token", size: paneSize(560)) { f in
                var model = f.settingsAccounts
                model.errors = [.gitlab: "That does not look like a token: it has spaces or quotes"]
                return SettingsPaneGalleryView(height: 560) { AccountsGalleryView(model: model, gitLabToken: "glpat abc") }
            },
            GalleryEntry(screen: "settings-accounts", state: "keychain-error", size: paneSize(560)) { f in
                var model = f.settingsAccounts
                model.gitLabSource = .missing(nil)
                model.errors = [.gitlab: "The keychain did not take the token"]
                return SettingsPaneGalleryView(height: 560) {
                    AccountsGalleryView(model: model, gitLabToken: "glpat-ExampleToken_123")
                }
            },
            GalleryEntry(screen: "settings-accounts", state: "long-values", size: paneSize(600)) { f in
                var model = f.settingsAccounts
                model.errors = [
                    .jenkins: "The keychain could not be read: security: SecKeychainSearchCopyNext: The specified item "
                        + "could not be found in the keychain, or the login keychain is locked and the user cancelled "
                        + "the request to unlock it (-25300)",
                ]
                model.results = f.settingsSignedIn
                return SettingsPaneGalleryView(height: 600) {
                    AccountsGalleryView(model: model, user: "maximiliane.konstanze.mueller-luedenscheidt")
                }
            },
        ]
    }
}
#endif
