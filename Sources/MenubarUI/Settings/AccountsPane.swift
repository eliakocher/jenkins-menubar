import MenubarCore
import SwiftUI

/// One token's section of Settings → Accounts (ACC-02, ACC-03, ACC-05, ACC-06, `docs/design/settings-accounts.md`):
/// where the token comes from, the fields of a new one, the link that creates one, Remove and Save, and why a token
/// couldn't be saved. The welcome flow's Accounts step can show the same sections. Put it inside a grouped `Form`.
public struct TokenSection: View {
    /// a field of the section, for its first keyboard focus
    public enum Field: Hashable, Sendable {
        /// the Jenkins user
        case user
        /// the new token
        case token
    }

    private let account: TokenAccount
    private let source: TokenSource
    private let user: Binding<String>?
    private let token: Binding<String>
    private let link: TokenLink?
    private let error: String?
    private let save: () -> Void
    private let remove: () -> Void
    private let initialFocus: Field?
    @FocusState private var focused: Field?

    /// - Parameters:
    ///   - account: Jenkins, with the user and the API token, or GitLab, with the personal access token
    ///   - source: `SettingsStore.tokenSource(_:)`
    ///   - user: the Jenkins user, filled from the stored token; ignored for GitLab
    ///   - token: the new token as typed; emptied after a Save
    ///   - link: `SettingsStore.tokenLink(_:)`; nil while the team value it needs is missing
    ///   - error: `SettingsStore.tokenErrors[account]`
    ///   - save: Save, and Return in the section's fields while Save is enabled
    ///   - remove: Remove, at once, without confirmation
    ///   - initialFocus: the field that takes the keyboard focus when the section appears (review WELCOME-05)
    public init(
        _ account: TokenAccount, source: TokenSource, user: Binding<String>? = nil, token: Binding<String>,
        link: TokenLink?, error: String?, save: @escaping () -> Void, remove: @escaping () -> Void,
        initialFocus: Field? = nil
    ) {
        self.account = account
        self.source = source
        self.user = user
        self.token = token
        self.link = link
        self.error = error
        self.save = save
        self.remove = remove
        self.initialFocus = initialFocus
    }

    public var body: some View {
        Section {
            LabeledContent("Token") {
                StatusLine(source.isStored ? .ok : .note, source.text)
            }
            if account == .jenkins, let user {
                TextField("User", text: user, prompt: Text("Your Jenkins user"))
                    .focused($focused, equals: .user)
                    .onSubmit(submit)
                SecureField("New API token", text: token, prompt: Text("Paste the API token from your Jenkins user page"))
                    .focused($focused, equals: .token)
                    .onSubmit(submit)
            } else {
                SecureField("New token", text: token, prompt: Text("Paste a personal access token with the api scope"))
                    .focused($focused, equals: .token)
                    .onSubmit(submit)
            }
            HStack {
                if let link {
                    Link(link.title, destination: link.url)
                }
                Spacer()
                if source.isStored {
                    Button("Remove", role: .destructive, action: remove)
                }
                Button("Save", action: save)
                    .disabled(!canSave)
            }
            if let error {
                StatusLine(.problem, error)
            }
        } header: {
            // On the header, a single view: a modifier on the section may go to each of its rows (inferred).
            Text(account == .jenkins ? "Jenkins" : "GitLab")
                .task {
                    if let initialFocus {
                        focused = initialFocus
                    }
                }
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

/// The account check's section (ACC-04): Check, a spinner in its place while it runs, and what each server said.
public struct AccountCheckSection: View {
    private let isChecking: Bool
    private let results: [TokenAccount: AccountStatus]
    private let check: () -> Void

    /// - Parameters:
    ///   - isChecking: `SettingsStore.isCheckingAccounts`
    ///   - results: `SettingsStore.accounts`
    ///   - check: runs the check again
    public init(isChecking: Bool, results: [TokenAccount: AccountStatus], check: @escaping () -> Void) {
        self.isChecking = isChecking
        self.results = results
        self.check = check
    }

    public var body: some View {
        Section {
            LabeledContent("Ask Jenkins and GitLab who is signed in") {
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Check", action: check)
                }
            }
            if !isChecking {
                ForEach([TokenAccount.jenkins, .gitlab], id: \.self) { account in
                    if let status = results[account] {
                        LabeledContent(account == .jenkins ? "Jenkins" : "GitLab") {
                            StatusLine(Self.kind(of: status), status.message)
                        }
                    }
                }
            }
        } header: {
            Text("Account Check")
        } footer: {
            SettingsFooter(
                "Tokens go to your login keychain under \(AppIdentity.keychainService), never to a file or the log. Saving or removing "
                    + "one starts a check.")
        }
    }

    /// It worked; nothing was asked, for want of a token or a team value; or what went wrong.
    nonisolated static func kind(of status: AccountStatus) -> StatusKind {
        if status.ok {
            return .ok
        }
        return [AccountStatus.noToken, .noJenkinsJob, .noGitLabURL].contains(status) ? .note : .problem
    }
}

/// The values of Settings → Accounts that come from the stores.
struct AccountsFormModel {
    var problems: [String] = []
    var jenkinsSource: TokenSource
    var gitLabSource: TokenSource
    var jenkinsLink: TokenLink?
    var gitLabLink: TokenLink?
    var errors: [TokenAccount: String] = [:]
    var isChecking = false
    var results: [TokenAccount: AccountStatus] = [:]
    /// the Jenkins server's host, from the first project's job; nil while there is none
    var jenkinsServer: String?
    /// what is wrong with the GitLab URL as typed
    var gitLabURLIssue: String?
}

/// What the Accounts pane's buttons do.
@MainActor
struct AccountsSettingsActions {
    var saveJenkins: () -> Void
    var saveGitLab: () -> Void
    var remove: (TokenAccount) -> Void
    var check: () -> Void
    /// opens Settings → Projects, where the Jenkins job is set
    var showProjects: () -> Void = {}

    /// does nothing, for the gallery
    static let none = AccountsSettingsActions(saveJenkins: {}, saveGitLab: {}, remove: { _ in }, check: {})
}

/// Settings → Accounts's form: GitLab with its URL (a team value) and token, Jenkins with its server (from Projects),
/// user and token, each with who the server says is signed in, and Check. It draws only what it is given.
struct AccountsSettingsForm: View {
    let model: AccountsFormModel
    @Binding var gitLabURL: String
    @Binding var jenkinsUser: String
    @Binding var jenkinsToken: String
    @Binding var gitLabToken: String
    let actions: AccountsSettingsActions

    var body: some View {
        Form {
            SettingsPaneHeader(pane: .accounts)
            SettingsProblemRows(model.problems)
            Section {
                SettingsTextRow(
                    "GitLab URL", text: $gitLabURL,
                    prompt: TeamValueFields.prompt(of: .gitLabURL), issue: model.gitLabURLIssue, width: 260, shared: true)
                    .settingsAnchor(.gitLabURL)
                statusRow(.gitlab, source: model.gitLabSource)
                LabeledContent {
                    SecureField("New token", text: $gitLabToken, prompt: Text("Paste a new token"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 260)
                        .onSubmit { if SettingsStore.canSaveGitLabToken(gitLabToken) { actions.saveGitLab() } }
                } label: {
                    SettingsRowLabel("New token", "Needs the api scope")
                }
                .settingsAnchor(.gitLabToken)
                buttons(
                    .gitlab, link: model.gitLabLink, isStored: model.gitLabSource.isStored,
                    canSave: SettingsStore.canSaveGitLabToken(gitLabToken), save: actions.saveGitLab)
                if let error = model.errors[.gitlab] {
                    StatusLine(.problem, error)
                }
            } header: {
                SettingsSectionHeader("GitLab")
            }
            Section {
                LabeledContent {
                    if let server = model.jenkinsServer {
                        Text(verbatim: server)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        Button("Add a Project…", action: actions.showProjects)
                    }
                } label: {
                    SettingsRowLabel("Server", "From your first project")
                }
                statusRow(.jenkins, source: model.jenkinsSource)
                LabeledContent {
                    TextField("User", text: $jenkinsUser, prompt: Text("Your Jenkins user"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 260)
                } label: {
                    SettingsRowLabel("User")
                }
                LabeledContent {
                    SecureField("New API token", text: $jenkinsToken, prompt: Text("Paste a new API token"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 260)
                        .onSubmit {
                            if SettingsStore.canSaveJenkinsToken(user: jenkinsUser, apiToken: jenkinsToken) {
                                actions.saveJenkins()
                            }
                        }
                } label: {
                    SettingsRowLabel("New API token")
                }
                .settingsAnchor(.jenkinsToken)
                buttons(
                    .jenkins, link: model.jenkinsLink, isStored: model.jenkinsSource.isStored,
                    canSave: SettingsStore.canSaveJenkinsToken(user: jenkinsUser, apiToken: jenkinsToken),
                    save: actions.saveJenkins)
                if let error = model.errors[.jenkins] {
                    StatusLine(.problem, error)
                }
            } header: {
                SettingsSectionHeader("Jenkins")
            }
            Section {
                LabeledContent {
                    if model.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Check Now", action: actions.check)
                    }
                } label: {
                    SettingsRowLabel("Check accounts", "Saving a token checks too")
                }
                .settingsAnchor(.accountCheck)
            } footer: {
                SettingsFooter(
                    "Tokens stay in your login keychain under \(AppIdentity.keychainService): never in a file, the team file or the log.")
            }
        }
        .formStyle(.grouped)
        .revealsSettingsFields()
    }

    /// Who the server says is signed in, or where the token is while nothing was asked yet.
    private func statusRow(_ account: TokenAccount, source: TokenSource) -> some View {
        LabeledContent {
            if model.isChecking {
                ProgressView()
                    .controlSize(.small)
            } else if let status = model.results[account] {
                StatusLine(AccountCheckSection.kind(of: status), status.message)
            } else {
                StatusLine(source.isStored ? .ok : .note, source.isStored ? "Token saved" : "No token yet")
            }
        } label: {
            SettingsRowLabel("Account", Self.whereStored(source))
        }
    }

    /// "Saved in your keychain", "Imported from ~/.zshrc into your keychain", or nil without a token.
    private static func whereStored(_ source: TokenSource) -> String? {
        switch source {
        case .keychain(nil): "Saved in your keychain"
        case .keychain(.oldKeychain?): "Imported from jenkins-menubar into your keychain"
        case .keychain(let from?): "Imported from \(from.displayName) into your keychain"
        case .missing(.zshrcComputed): source.text
        case .missing: nil
        }
    }

    private func buttons(
        _ account: TokenAccount, link: TokenLink?, isStored: Bool, canSave: Bool, save: @escaping () -> Void
    ) -> some View {
        HStack {
            if let link {
                Link(destination: link.url) {
                    Label(link.title, systemImage: "arrow.up.forward.square")
                }
            }
            Spacer()
            if isStored {
                Button("Remove Token", role: .destructive) { actions.remove(account) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
            Button("Save Token", action: save)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
        }
    }
}

/// Settings → Accounts, from the stores: the primary project's GitLab URL and the tokens. The first showing in a
/// session with a token stored runs the account check by itself, and so does a Save while the pane shows (ACC-04).
struct AccountsPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(PipelinesStore.self) private var pipelines
    @Environment(MergeRequestsStore.self) private var mergeRequests
    @Environment(WorkItemsStore.self) private var workItems
    @ViewState private var jenkinsUser = ""
    @ViewState private var jenkinsToken = ""
    @ViewState private var gitLabToken = ""
    @ViewState private var isTyping = false

    var body: some View {
        AccountsSettingsForm(
            model: model,
            gitLabURL: Binding(get: { settings.teamDraft.gitLabURL }, set: { settings.teamDraft.gitLabURL = $0 }),
            jenkinsUser: $jenkinsUser, jenkinsToken: $jenkinsToken, gitLabToken: $gitLabToken,
            actions: actions)
            .modifier(TeamDraftTyping(draft: settings.teamDraft, isTyping: $isTyping))
            .onAppear {
                settings.editPrimaryProject()
                jenkinsUser = settings.jenkinsUser
                let settings = settings
                // Not a `task`: leaving the pane must not cancel the check's requests.
                Task { await settings.accountsAppeared() }
            }
            .onDisappear {
                settings.saveTeamNow()
                settings.accountsDisappeared()
            }
            .onChange(of: settings.jenkinsUser) {
                jenkinsUser = settings.jenkinsUser
            }
    }

    private var model: AccountsFormModel {
        AccountsFormModel(
            problems: SettingsProblemRows.texts(
                for: .accounts, from: [pipelines.problem, mergeRequests.problem, workItems.problem]),
            jenkinsSource: settings.tokenSource(.jenkins), gitLabSource: settings.tokenSource(.gitlab),
            jenkinsLink: settings.tokenLink(.jenkins), gitLabLink: settings.tokenLink(.gitlab),
            errors: settings.tokenErrors, isChecking: settings.isCheckingAccounts, results: settings.accounts,
            jenkinsServer: settings.primaryTeam.jenkinsJob?.host(),
            gitLabURLIssue: isTyping ? nil : settings.teamIssue(for: .gitLabURL))
    }

    private var actions: AccountsSettingsActions {
        let settings = settings
        return AccountsSettingsActions(
            saveJenkins: {
                let user = jenkinsUser
                let token = jenkinsToken
                // Emptied at once: a saved token waits for the checks it starts; a refused one comes back.
                jenkinsToken = ""
                Task {
                    if await !settings.saveJenkinsToken(user: user, apiToken: token) {
                        jenkinsToken = token
                    }
                }
            },
            saveGitLab: {
                let token = gitLabToken
                gitLabToken = ""
                Task {
                    if await !settings.saveGitLabToken(token) {
                        gitLabToken = token
                    }
                }
            },
            remove: { account in
                Task { await settings.removeToken(account) }
            },
            check: {
                Task { await settings.checkAccounts() }
            },
            showProjects: { settings.selectedPane = .projects })
    }
}
