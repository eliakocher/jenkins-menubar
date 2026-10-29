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
                "Tokens go to your login keychain under menubar-monitor, never to a file or the log. Saving or removing "
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
}

/// What the Accounts pane's buttons do.
@MainActor
struct AccountsSettingsActions {
    var saveJenkins: () -> Void
    var saveGitLab: () -> Void
    var remove: (TokenAccount) -> Void
    var check: () -> Void

    /// does nothing, for the gallery
    static let none = AccountsSettingsActions(saveJenkins: {}, saveGitLab: {}, remove: { _ in }, check: {})
}

/// Settings → Accounts's form: the problem rows, the two tokens and the account check. It draws only what it is given.
struct AccountsSettingsForm: View {
    let model: AccountsFormModel
    @Binding var jenkinsUser: String
    @Binding var jenkinsToken: String
    @Binding var gitLabToken: String
    let actions: AccountsSettingsActions

    var body: some View {
        Form {
            SettingsProblemRows(model.problems)
            TokenSection(
                .jenkins, source: model.jenkinsSource, user: $jenkinsUser, token: $jenkinsToken, link: model.jenkinsLink,
                error: model.errors[.jenkins], save: actions.saveJenkins, remove: { actions.remove(.jenkins) })
            TokenSection(
                .gitlab, source: model.gitLabSource, token: $gitLabToken, link: model.gitLabLink,
                error: model.errors[.gitlab], save: actions.saveGitLab, remove: { actions.remove(.gitlab) })
            AccountCheckSection(isChecking: model.isChecking, results: model.results, check: actions.check)
        }
        .formStyle(.grouped)
    }
}

/// Settings → Accounts, from the stores. The first showing in a session with a token stored runs the account check by
/// itself, and so does a Save while the pane shows (ACC-04).
struct AccountsPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(PipelinesStore.self) private var pipelines
    @Environment(MergeRequestsStore.self) private var mergeRequests
    @Environment(WorkItemsStore.self) private var workItems
    @ViewState private var jenkinsUser = ""
    @ViewState private var jenkinsToken = ""
    @ViewState private var gitLabToken = ""

    var body: some View {
        AccountsSettingsForm(
            model: model, jenkinsUser: $jenkinsUser, jenkinsToken: $jenkinsToken, gitLabToken: $gitLabToken,
            actions: actions)
            .onAppear {
                jenkinsUser = settings.jenkinsUser
                let settings = settings
                // Not a `task`: leaving the pane must not cancel the check's requests.
                Task { await settings.accountsAppeared() }
            }
            .onDisappear {
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
            errors: settings.tokenErrors, isChecking: settings.isCheckingAccounts, results: settings.accounts)
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
            })
    }
}
