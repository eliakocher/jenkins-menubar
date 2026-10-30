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

/// The welcome flow's window content: the page's heading and form above a bottom bar with the step and the buttons
/// (`docs/design/welcome.md`). It draws only what it is given.
struct WelcomeContent: View {
    /// the window's content size, fixed
    nonisolated static let size = CGSize(width: 600, height: 560)

    let data: WelcomeData
    @Binding var input: WelcomeInput
    var actions = WelcomeContentActions()

    var body: some View {
        // The heading stays above the form: in an empty section's header it changed the next header's style.
        VStack(alignment: .leading, spacing: 0) {
            header
            Form {
                page
            }
            .formStyle(.grouped)
        }
        .safeAreaBar(edge: .bottom) {
            bottomBar
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    // MARK: - Header and bottom bar

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if data.page == .welcome {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
            }
            Text(data.page == .done ? data.summary.heading : data.page.heading)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            if let intro {
                Text(intro)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            if data.page == .welcome, data.importSummary.isFresh {
                Text(WelcomeImportSummary.freshText)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            if data.page == .team {
                teamFileImport
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        // On the section headers' text below, which the grouped form insets by its margin and the rows' own.
        .padding(.horizontal, Self.headerInset)
        .padding(.top, 20)
    }

    /// the grouped form's leading inset of its section headers' text
    private static let headerInset: CGFloat = 30

    /// the paragraph under the heading; page 6 says where to find the app
    private var intro: String? {
        data.page == .done ? data.summary.whereToFind : data.page.intro(notifications: data.notifications)
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

    private var teamFileImport: some View {
        WelcomeTeamFileImport(
            result: data.team.fileResult ?? (data.team.importedFromOldTool ? .ok("Imported from jenkins-menubar") : nil),
            importTeamFile: actions.importTeamFile)
    }

    /// Settings → Team's fields; Return in a field presses Continue, which saves first (`welcome.md`, Keyboard), and
    /// while Continue is disabled shows why instead of moving on.
    @ViewBuilder private var teamSections: some View {
        WelcomeNoteRows(data.team.notes)
        SettingsProblemRows(data.team.problems)
        TeamValueFields(
            values: $input.team, issues: data.team.issues,
            onSubmit: {
                if data.canContinue {
                    actions.next()
                } else {
                    actions.teamNotReady()
                }
            },
            onLeave: { actions.leftTeamField($0) }, showsConventions: false, initialFocus: .jenkinsJobURL)
    }

    // MARK: Accounts (ACC-01 to ACC-06)

    /// Settings → Accounts' sections: a token typed but not saved is saved by Continue too. The check's problems show
    /// on top, as Settings → Accounts shows the stores' problems: its own section is below the fold.
    @ViewBuilder private var accountsSections: some View {
        SettingsProblemRows(data.accounts.problems)
        TokenSection(
            .jenkins, source: data.accounts.sources[.jenkins] ?? .missing(nil), user: $input.jenkinsUser,
            token: $input.jenkinsToken, link: data.accounts.links[.jenkins], error: data.accounts.errors[.jenkins],
            save: { actions.saveToken(.jenkins) }, remove: { actions.removeToken(.jenkins) },
            initialFocus: input.jenkinsUser.isEmpty ? .user : .token)
        TokenSection(
            .gitlab, source: data.accounts.sources[.gitlab] ?? .missing(nil), token: $input.gitLabToken,
            link: data.accounts.links[.gitlab], error: data.accounts.errors[.gitlab],
            save: { actions.saveToken(.gitlab) }, remove: { actions.removeToken(.gitlab) })
        AccountCheckSection(
            isChecking: data.accounts.isChecking, results: data.accounts.results, check: { actions.checkAccounts() })
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
            // Only the intro: the page's one button asks.
            EmptyView()
        }
    }

    // MARK: Menu bar and login (APP-01, APP-02)

    private var menuBarAndLoginSections: some View {
        Section {
            Toggle("Show in menu bar", isOn: $input.showInMenuBar)
                .settingsSwitch()
            OpenAtLoginRows(
                isOn: data.login.status == .notFound ? .constant(false) : $input.openAtLogin,
                status: data.login.status, error: data.login.error, openSystemSettings: actions.openLoginItemsSettings)
        } footer: {
            SettingsFooter(
                "Open at login starts MegaMonitor when you log in. Checks and alerts go on while the menu bar icon "
                    + "is hidden; open MegaMonitor again to get to its window.")
        }
    }

    // MARK: Done (IMP-03)

    @ViewBuilder private var doneSections: some View {
        if !data.summary.stillMissing.isEmpty {
            Section("Still Missing") {
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
            }
        }
        if !data.summary.didNotMove.isEmpty {
            Section("Didn't Move from jenkins-menubar") {
                ForEach(data.summary.didNotMove, id: \.self) { text in
                    StatusLine(.note, text)
                }
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
            Section("Imported from jenkins-menubar") {
                ForEach(summary.imported, id: \.self) { line in
                    StatusLine(.ok, line)
                }
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
    }
}

/// Import Team File… and its result under it (TEAM-02).
private struct WelcomeTeamFileImport: View {
    let result: WelcomeLine?
    let importTeamFile: @MainActor (Result<URL, any Error>) -> Void
    @ViewState private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Import Team File…") {
                importing = true
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json], onCompletion: importTeamFile)
            if let result {
                StatusLine(result.kind, result.text)
            }
        }
        .padding(.top, 4)
    }
}
