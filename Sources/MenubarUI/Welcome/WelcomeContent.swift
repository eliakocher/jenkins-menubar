import AppKit
import MenubarCore
import SwiftUI
import UniformTypeIdentifiers

/// What the welcome flow shows, as plain values: ``WelcomeView`` fills it from the stores, the gallery from fixtures.
struct WelcomeData {
    var page: WelcomePage
    /// page 1
    var importSummary = WelcomeImportSummary(imported: [], folderMissing: false)
    /// page 1: a chosen folder that isn't the old tool's, until the next choice
    var wrongFolder = false
    /// page 2
    var team = Team()
    /// page 3
    var accounts = Accounts()
    /// page 4; nil while it isn't read yet
    var notifications: NotificationPermission?
    /// the saved preferences, for the notification line
    var preferences = Preferences()
    /// page 5
    var login = Login()
    /// page 6
    var summary = WelcomeSummary(heading: WelcomePage.done.heading, whereToFind: "", stillMissing: [], didNotMove: [])
    /// whether the page's button is at work, like saving a typed token
    var isBusy = false

    /// The Team page: the rows on top, the issues under the fields, and Import Team File…'s result.
    struct Team {
        /// the TEAM-03 row while a required value isn't saved and people haven't tried to move on yet: a note, since
        /// the intro asks for the values already
        var notes: [String] = []
        /// the TEAM-03 row after a Continue or Return that couldn't move on, or a required field left empty; a save
        /// that failed
        var problems: [String] = []
        /// the issues the fields show now (TEAM-01)
        var issues: [TeamValues.Key: String] = [:]
        /// whether the values came from jenkins-menubar: an ok line on top
        var importedFromOldTool = false
        /// what Import Team File… did, under the button
        var fileResult: WelcomeLine?
        /// whether the three required values can be saved (TEAM-03)
        var canContinue = false
    }

    /// The Accounts page, as Settings → Accounts shows it (ACC-02 to ACC-06).
    struct Accounts {
        var sources: [TokenAccount: TokenSource] = [:]
        var links: [TokenAccount: TokenLink] = [:]
        var errors: [TokenAccount: String] = [:]
        var isChecking = false
        var results: [TokenAccount: AccountStatus] = [:]

        /// the check's problems, for the top of the page, where the bottom bar can't hide them; none while it runs, as
        /// its section shows none
        @MainActor var problems: [String] {
            guard !isChecking else { return [] }
            var problems: [String] = []
            for account in TokenAccount.allCases {
                if let status = results[account], AccountCheckSection.kind(of: status) == .problem,
                    !problems.contains(status.message)
                {
                    problems.append(status.message)
                }
            }
            return problems
        }
    }

    /// The login item on page 5 (APP-02).
    struct Login {
        var status: LoginItemStatus = .notRegistered
        var error: String?
    }

    /// whether the page's button is enabled
    var canContinue: Bool {
        !isBusy && (page != .team || team.canContinue)
    }
}

/// What people type and switch in the flow; the live view binds it to the stores.
struct WelcomeInput: Equatable {
    var team = TeamValues()
    var jenkinsUser = ""
    var jenkinsToken = ""
    var gitLabToken = ""
    var showInMenuBar = true
    /// starts on; registered when Continue is pressed on page 5 (APP-02)
    var openAtLogin = true
}

/// What the content's buttons do; the gallery's do nothing.
struct WelcomeContentActions {
    var next: @MainActor () -> Void = {}
    var back: @MainActor () -> Void = {}
    var importTeamFile: @MainActor (Result<URL, any Error>) -> Void = { _ in }
    /// a team field lost the keyboard focus: its issue shows (TEAM-01)
    var leftTeamField: @MainActor (TeamValues.Key) -> Void = { _ in }
    /// Return in a team field while Continue is disabled: the issues and the TEAM-03 row show now
    var teamNotReady: @MainActor () -> Void = {}
    var chooseFolder: @MainActor (URL) -> Void = { _ in }
    var saveToken: @MainActor (TokenAccount) -> Void = { _ in }
    var removeToken: @MainActor (TokenAccount) -> Void = { _ in }
    var checkAccounts: @MainActor () -> Void = {}
    var openNotificationSettings: @MainActor () -> Void = {}
    var openLoginItemsSettings: @MainActor () -> Void = {}
}

/// The welcome flow's window content: a grouped form that starts with the step's header, as the Settings panes do,
/// above a bottom bar with the step and the buttons (`docs/design/welcome.md`). It draws only what it is given.
struct WelcomeContent: View {
    /// the window's content size, fixed
    nonisolated static let size = CGSize(width: 600, height: 560)

    let data: WelcomeData
    @Binding var input: WelcomeInput
    var actions = WelcomeContentActions()

    var body: some View {
        Form {
            WelcomeStepHeader(
                symbol: headerSymbol, tint: headerTint, title: data.page == .done ? data.summary.heading : data.page.heading,
                summary: intro)
            page
        }
        .formStyle(.grouped)
        .safeAreaBar(edge: .bottom) {
            bottomBar
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    // MARK: - Header and bottom bar

    /// the line under the heading; page 6 says where to find the app
    private var intro: String? {
        data.page == .done ? data.summary.whereToFind : data.page.intro
    }

    private var headerSymbol: String {
        data.page == .done && data.summary.heading != WelcomePage.done.heading
            ? "exclamationmark.circle.fill" : data.page.symbol
    }

    /// the tint of the matching Settings pane, as its sidebar icon has it
    private var headerTint: Color {
        switch data.page {
        case .welcome: .blue
        case .team: SettingsPane.projects.tint
        case .accounts: SettingsPane.accounts.tint
        case .notifications: SettingsPane.notifications.tint
        case .menuBarAndLogin: SettingsPane.general.tint
        case .done: data.summary.heading == WelcomePage.done.heading ? .green : .orange
        }
    }

    private var bottomBar: some View {
        HStack {
            Text(data.page.stepText)
                .foregroundStyle(.secondary)
            Spacer()
            if data.page.showsBack(notifications: data.notifications) {
                Button("Back", action: actions.back)
            }
            Button(data.page.buttonTitle, action: actions.next)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!data.canContinue)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Pages

    @ViewBuilder private var page: some View {
        switch data.page {
        case .welcome:
            WelcomeImportSections(
                summary: data.importSummary, wrongFolder: data.wrongFolder, chooseFolder: actions.chooseFolder)
        case .team: teamSections
        case .accounts: accountsSections
        case .notifications: notificationSections
        case .menuBarAndLogin: menuBarAndLoginSections
        case .done: doneSections
        }
    }

    // MARK: Team (TEAM-01 to TEAM-03)

    /// Settings → Projects' rows; Return in a field presses Continue, which saves first (`welcome.md`, Keyboard), and
    /// while Continue is disabled shows why instead of moving on.
    @ViewBuilder private var teamSections: some View {
        WelcomeNoteRows(data.team.notes)
        SettingsProblemRows(data.team.problems)
        WelcomeTeamFileImport(
            result: data.team.fileResult ?? (data.team.importedFromOldTool ? .ok("Imported from jenkins-menubar") : nil),
            importTeamFile: actions.importTeamFile)
        WelcomeTeamFields(
            values: $input.team, issues: data.team.issues,
            onSubmit: {
                if data.canContinue {
                    actions.next()
                } else {
                    actions.teamNotReady()
                }
            },
            onLeave: { actions.leftTeamField($0) })
    }

    // MARK: Accounts (ACC-01 to ACC-06)

    /// Settings → Accounts' sections: a token typed but not saved is saved by Continue too. The check's problems show
    /// on top, as Settings → Accounts shows the stores' problems: its own section is below the fold.
    @ViewBuilder private var accountsSections: some View {
        SettingsProblemRows(data.accounts.problems)
        WelcomeTokenSection(
            .jenkins, source: data.accounts.sources[.jenkins] ?? .missing(nil),
            result: data.accounts.results[.jenkins], isChecking: data.accounts.isChecking, user: $input.jenkinsUser,
            token: $input.jenkinsToken, link: data.accounts.links[.jenkins], error: data.accounts.errors[.jenkins],
            save: { actions.saveToken(.jenkins) }, remove: { actions.removeToken(.jenkins) },
            initialFocus: input.jenkinsUser.isEmpty ? .user : .token)
        WelcomeTokenSection(
            .gitlab, source: data.accounts.sources[.gitlab] ?? .missing(nil),
            result: data.accounts.results[.gitlab], isChecking: data.accounts.isChecking, token: $input.gitLabToken,
            link: data.accounts.links[.gitlab], error: data.accounts.errors[.gitlab],
            save: { actions.saveToken(.gitlab) }, remove: { actions.removeToken(.gitlab) })
        Section {
            LabeledContent {
                if data.accounts.isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Check Now", action: actions.checkAccounts)
                }
            } label: {
                SettingsRowLabel("Check accounts", "Saving a token checks too")
            }
        }
    }

    // MARK: Notifications (APP-04)

    @ViewBuilder private var notificationSections: some View {
        switch data.notifications {
        case .allowed:
            Section {
                StatusLine(.ok, WelcomeNotificationText.allowed)
            }
        case .off:
            Section {
                StatusLine(.note, WelcomeNotificationText.off(data.preferences)) {
                    Button("Open System Settings…", action: actions.openNotificationSettings)
                }
            }
        case .notAsked, nil:
            // The page's one button asks; the line says so before (HIG Privacy).
            Section {
                StatusLine(.note, "When you continue, macOS asks whether MegaMonitor may show notifications")
            }
        }
    }

    // MARK: Menu bar and login (APP-01, APP-02)

    private var menuBarAndLoginSections: some View {
        Section {
            Toggle(isOn: $input.showInMenuBar) {
                SettingsRowLabel("Show in menu bar", "Open MegaMonitor again to reach its window while it is hidden")
            }
            .settingsSwitch()
            OpenAtLoginRows(
                isOn: data.login.status == .notFound ? .constant(false) : $input.openAtLogin,
                status: data.login.status, error: data.login.error, openSystemSettings: actions.openLoginItemsSettings,
                caption: "Starts MegaMonitor when you log in")
        }
    }

    // MARK: Done (IMP-03)

    @ViewBuilder private var doneSections: some View {
        if !data.summary.stillMissing.isEmpty {
            Section {
                ForEach(data.summary.stillMissing) { line in
                    if let page = line.opens {
                        StatusLine(line.kind, line.text) {
                            Button("Open System Settings…") {
                                open(page)
                            }
                        }
                    } else {
                        StatusLine(line.kind, line.text)
                    }
                }
            } header: {
                SettingsSectionHeader("Still Missing")
            }
        }
        if !data.summary.didNotMove.isEmpty {
            Section {
                ForEach(data.summary.didNotMove, id: \.self) { text in
                    StatusLine(.note, text)
                }
            } header: {
                SettingsSectionHeader("Didn't Move from jenkins-menubar")
            }
        }
        if let eggLine = data.summary.eggLine {
            // An easter egg (EGG-22): one quiet line under what the page says.
            Section {
                Text(verbatim: eggLine)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func open(_ page: WelcomeLine.SystemSettingsPage) {
        switch page {
        case .notifications: actions.openNotificationSettings()
        case .loginItems: actions.openLoginItemsSettings()
        }
    }
}

/// The top of a step, as ``SettingsPaneHeader`` starts a pane: a large white symbol in a colored rounded square, the
/// step's title, and what it is for.
private struct WelcomeStepHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let summary: String?

    var body: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: tint.opacity(0.35), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .font(.title3.weight(.semibold))
                    if let summary {
                        Text(verbatim: summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }
}

/// The TEAM-03 row before people tried to move on: a note, drawn as ``SettingsProblemRows`` draws a problem, so that it
/// keeps its place and size when it turns into one.
private struct WelcomeNoteRows: View {
    private let notes: [String]

    init(_ notes: [String]) {
        self.notes = notes
    }

    var body: some View {
        if !notes.isEmpty {
            Section {
                ForEach(notes, id: \.self) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: StatusKind.note.symbol)
                            .foregroundStyle(StatusKind.note.color)
                        Text(verbatim: note)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// The team values as Settings → Projects shows them: the Jenkins job stacked over its full-width field, the GitLab URL
/// and project beside theirs, all marked Shared. Return presses Continue; a field that lost the focus shows its issue
/// (TEAM-01).
private struct WelcomeTeamFields: View {
    @Binding var values: TeamValues
    let issues: [TeamValues.Key: String]
    let onSubmit: () -> Void
    let onLeave: (TeamValues.Key) -> Void
    @FocusState private var focused: TeamValues.Key?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                SettingsRowLabel("Jenkins job", "The multibranch job, as the browser shows it")
                field(.jenkinsJobURL, "Jenkins job")
                    .frame(maxWidth: .infinity)
            }
            issue(.jenkinsJobURL)
            LabeledContent {
                field(.gitLabURL, "GitLab URL")
                    .frame(width: 260)
            } label: {
                SettingsRowLabel("GitLab URL")
            }
            issue(.gitLabURL)
            LabeledContent {
                field(.gitLabProject, "GitLab project")
                    .frame(width: 260)
            } label: {
                SettingsRowLabel("GitLab project")
            }
            issue(.gitLabProject)
        } header: {
            // The focus's watchers hang on a single view that always shows: a modifier on a section may go to each of
            // its rows (inferred).
            SettingsSectionHeader("Team Values", shared: true)
                .onChange(of: focused) { old, _ in
                    if let old {
                        onLeave(old)
                    }
                }
                .task {
                    focused = .jenkinsJobURL
                }
        }
    }

    private func field(_ key: TeamValues.Key, _ title: String) -> some View {
        TextField(
            title, text: Binding(get: { values[key] }, set: { values[key] = $0 }),
            prompt: Text(verbatim: key.prompt)
        )
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.leading)
        .focused($focused, equals: key)
        .onSubmit(onSubmit)
        .help(values[key])
    }

    @ViewBuilder private func issue(_ key: TeamValues.Key) -> some View {
        if let issue = issues[key] {
            StatusLine(.problem, issue)
        }
    }
}

/// One token's section of Settings → Accounts, in its new look: who is signed in, the fields of a new token, the link
/// that creates one, Remove and Save Token, and why a token couldn't be saved (ACC-02, ACC-03, ACC-05, ACC-06).
private struct WelcomeTokenSection: View {
    enum Field: Hashable {
        case user
        case token
    }

    private let account: TokenAccount
    private let source: TokenSource
    private let result: AccountStatus?
    private let isChecking: Bool
    private let user: Binding<String>?
    private let token: Binding<String>
    private let link: TokenLink?
    private let error: String?
    private let save: () -> Void
    private let remove: () -> Void
    private let initialFocus: Field?
    @FocusState private var focused: Field?

    init(
        _ account: TokenAccount, source: TokenSource, result: AccountStatus?, isChecking: Bool,
        user: Binding<String>? = nil, token: Binding<String>, link: TokenLink?, error: String?,
        save: @escaping () -> Void, remove: @escaping () -> Void, initialFocus: Field? = nil
    ) {
        self.account = account
        self.source = source
        self.result = result
        self.isChecking = isChecking
        self.user = user
        self.token = token
        self.link = link
        self.error = error
        self.save = save
        self.remove = remove
        self.initialFocus = initialFocus
    }

    var body: some View {
        Section {
            LabeledContent {
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else if let result {
                    StatusLine(AccountCheckSection.kind(of: result), result.message)
                } else {
                    StatusLine(source.isStored ? .ok : .note, source.isStored ? "Token saved" : "No token yet")
                }
            } label: {
                SettingsRowLabel("Account", whereStored)
            }
            if account == .jenkins, let user {
                LabeledContent {
                    TextField("User", text: user, prompt: Text("Your Jenkins user"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 260)
                        .focused($focused, equals: .user)
                        .onSubmit(submit)
                } label: {
                    SettingsRowLabel("User")
                }
                LabeledContent {
                    SecureField("New API token", text: token, prompt: Text("Paste a new API token"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 260)
                        .focused($focused, equals: .token)
                        .onSubmit(submit)
                } label: {
                    SettingsRowLabel("New API token", "From your Jenkins user page")
                }
            } else {
                LabeledContent {
                    SecureField("New token", text: token, prompt: Text("Paste a new token"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 260)
                        .focused($focused, equals: .token)
                        .onSubmit(submit)
                } label: {
                    SettingsRowLabel("New token", "Needs the api scope")
                }
            }
            HStack {
                if let link {
                    Link(destination: link.url) {
                        Label(link.title, systemImage: "arrow.up.forward.square")
                    }
                }
                Spacer()
                if source.isStored {
                    Button("Remove Token", role: .destructive, action: remove)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
                Button("Save Token", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            if let error {
                StatusLine(.problem, error)
            }
        } header: {
            // On the header, a single view: a modifier on the section may go to each of its rows (inferred).
            SettingsSectionHeader(account == .jenkins ? "Jenkins" : "GitLab")
                .task {
                    if let initialFocus {
                        focused = initialFocus
                    }
                }
        }
    }

    /// where the stored token came from, or nil without one
    private var whereStored: String? {
        switch source {
        case .keychain(nil): "Saved in your keychain"
        case .keychain(.oldKeychain?): "Imported from jenkins-menubar into your keychain"
        case .keychain(let from?): "Imported from \(from.displayName) into your keychain"
        case .missing(.zshrcComputed): source.text
        case .missing: nil
        }
    }

    private var canSave: Bool {
        account == .jenkins
            ? SettingsStore.canSaveJenkinsToken(user: user?.wrappedValue ?? "", apiToken: token.wrappedValue)
            : SettingsStore.canSaveGitLabToken(token.wrappedValue)
    }

    private func submit() {
        if canSave {
            save()
        }
    }
}

/// Page 1's import from jenkins-menubar: what was imported, and "Choose Folder…" when the old folder wasn't found
/// (IMP-01).
private struct WelcomeImportSections: View {
    let summary: WelcomeImportSummary
    /// a chosen folder wasn't the old tool's: a problem line under the note
    let wrongFolder: Bool
    let chooseFolder: @MainActor (URL) -> Void
    @ViewState private var choosing = false

    var body: some View {
        if !summary.imported.isEmpty {
            Section {
                ForEach(summary.imported, id: \.self) { line in
                    StatusLine(.ok, line)
                }
            } header: {
                SettingsSectionHeader("Imported from jenkins-menubar")
            }
        }
        if summary.folderMissing {
            Section {
                StatusLine(.note, WelcomeImportSummary.folderMissingText) {
                    Button("Choose Folder…") {
                        choosing = true
                    }
                }
                .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                    if case .success(let folder) = result {
                        chooseFolder(folder)
                    }
                }
                if wrongFolder {
                    StatusLine(.problem, WelcomeImportSummary.wrongFolderText)
                }
            }
        }
        if summary.isFresh {
            Section {
                StatusLine(.note, WelcomeImportSummary.freshText)
            }
        }
    }
}

/// Import Team File… and its result under it (TEAM-02).
private struct WelcomeTeamFileImport: View {
    let result: WelcomeLine?
    let importTeamFile: @MainActor (Result<URL, any Error>) -> Void
    @ViewState private var importing = false

    var body: some View {
        Section {
            LabeledContent {
                Button("Import Team File…") {
                    importing = true
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json], onCompletion: importTeamFile)
            } label: {
                SettingsRowLabel("Team file", "Ask a colleague for it, or fill in the values below")
            }
            if let result {
                StatusLine(result.kind, result.text)
            }
        }
    }
}
