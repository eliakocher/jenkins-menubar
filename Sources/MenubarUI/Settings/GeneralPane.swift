import AppKit
import MenubarCore
import SwiftUI

/// Whether macOS shows the app's banners, as the app reads its notification settings (APP-04).
public enum NotificationPermission: Hashable, Sendable {
    /// banners show
    case allowed
    /// denied, or the app's style in System Settings is None
    case off
    /// macOS never asked, as when the welcome flow was closed early
    case notAsked
}

/// The notification row of Settings → General (APP-04): only while banners are in use, the Banner style or stage
/// banners on, and macOS doesn't show them.
public struct NotificationNotice: Hashable, Sendable {
    /// ``NotificationPermission/off`` or ``NotificationPermission/notAsked``
    public var permission: NotificationPermission
    /// what doesn't show, like "Notifications are off for MegaMonitor: stage banners don't show"
    public var text: String

    /// a problem while notifications are off, a note while macOS never asked
    public var kind: StatusKind {
        permission == .off ? .problem : .note
    }

    /// "Open System Settings…" while they are off; "Turn On Notifications…", after which macOS asks, while it never
    /// asked
    public var buttonTitle: String {
        permission == .off ? "Open System Settings…" : "Turn On Notifications…"
    }

    /// Returns the row for the permission and the alert settings, or nil when none shows.
    ///
    /// - Parameters:
    ///   - permission: what macOS allows; nil while it isn't known yet, which shows nothing rather than a spinner
    ///   - preferences: the alert style and the stage banners
    /// - Returns: the row
    public static func of(_ permission: NotificationPermission?, preferences: Preferences) -> NotificationNotice? {
        let banners = preferences.alertStyle == .banner
        let stageBanners = preferences.stageAlerts
        guard banners || stageBanners, let permission, permission != .allowed else { return nil }
        let off = permission == .off
        var parts: [String] = []
        if stageBanners {
            parts.append(off ? "stage banners don't show" : "stage banners can't show")
        }
        if banners {
            parts.append("banners show as the alert window")
        }
        let start = off ? "Notifications are off for MegaMonitor" : "Notifications aren't set up yet"
        return NotificationNotice(permission: permission, text: "\(start): \(parts.joined(separator: ", and "))")
    }
}

/// What the General pane does beyond its values: the system's settings, the permission prompt and the previews.
@MainActor
public struct GeneralSettingsActions {
    /// opens System Settings → General → Login Items
    public var openLoginItemsSettings: @MainActor () -> Void
    /// opens the app's pane in System Settings → Notifications
    public var openNotificationSettings: @MainActor () -> Void
    /// asks macOS for the notification permission, which it does once
    public var turnOnNotifications: @MainActor () -> Void
    /// shows the alert the current settings choose for a sample (ALERT-07)
    public var preview: @MainActor (BuildAlert.PreviewSample) -> Void

    public init(
        openLoginItemsSettings: @escaping @MainActor () -> Void,
        openNotificationSettings: @escaping @MainActor () -> Void,
        turnOnNotifications: @escaping @MainActor () -> Void,
        preview: @escaping @MainActor (BuildAlert.PreviewSample) -> Void
    ) {
        self.openLoginItemsSettings = openLoginItemsSettings
        self.openNotificationSettings = openNotificationSettings
        self.turnOnNotifications = turnOnNotifications
        self.preview = preview
    }

    /// does nothing, for the gallery
    public static let none = GeneralSettingsActions(
        openLoginItemsSettings: {}, openNotificationSettings: {}, turnOnNotifications: {}, preview: { _ in })
}

/// The "Open at login" switch and its status line (APP-02): waiting for approval with "Open System Settings…", not
/// found with the switch disabled, or why a change was refused. The welcome flow can show the same rows.
public struct OpenAtLoginRows: View {
    private let isOn: Binding<Bool>
    private let status: LoginItemStatus
    private let error: String?
    private let openSystemSettings: @MainActor () -> Void
    private let caption: String?

    /// - Parameters:
    ///   - isOn: the switch; Settings binds it to the login item's status
    ///   - status: the login item's status
    ///   - error: why the last change was refused
    ///   - openSystemSettings: opens System Settings → General → Login Items
    ///   - caption: the line under the switch's name; nil for none, as in the welcome flow
    public init(
        isOn: Binding<Bool>, status: LoginItemStatus, error: String?,
        openSystemSettings: @escaping @MainActor () -> Void, caption: String? = nil
    ) {
        self.caption = caption
        self.isOn = isOn
        self.status = status
        self.error = error
        self.openSystemSettings = openSystemSettings
    }

    public var body: some View {
        Toggle(isOn: isOn) {
            SettingsRowLabel("Open at login", caption)
        }
        .settingsSwitch()
        .settingsAnchor(.openAtLogin)
            .disabled(status == .notFound)
        if let error {
            StatusLine(.problem, error)
        } else if let message = status.message {
            StatusLine(.note, message) {
                if status.needsApproval {
                    Button("Open System Settings…", action: openSystemSettings)
                }
            }
        }
    }
}

/// The "Open GitLab and Jenkins Links in MegaMonitor" switch and what it shows (APP-09).
public struct LinkRoutingSwitch {
    /// the switch; setting it asks macOS, which may refuse
    public var isOn: Binding<Bool>
    /// the browser that gets every other link: the remembered one
    public var browserName: String
    /// the quiet note after a refusal; `nil` for none
    public var note: String?
    /// whether macOS is being asked, which disables the switch
    public var isChanging: Bool

    public init(isOn: Binding<Bool>, browserName: String, note: String?, isChanging: Bool) {
        self.isOn = isOn
        self.browserName = browserName
        self.note = note
        self.isChanging = isChanging
    }
}

/// Settings → General's form: how MegaMonitor starts and shows, the window's shortcut, the links, and the easter eggs.
/// It draws only what it is given.
public struct GeneralSettingsForm: View {
    @Binding private var preferences: Preferences
    private let openAtLogin: Binding<Bool>
    private let loginStatus: LoginItemStatus
    private let loginError: String?
    private let hotkey: HotkeyStatus
    private let isRecordingShortcut: Bool
    private let actions: GeneralSettingsActions
    private let linkRouting: LinkRoutingSwitch?

    /// - Parameters:
    ///   - preferences: the preferences; a change saves at once
    ///   - openAtLogin: the switch of the login item
    ///   - loginStatus: the login item's status
    ///   - loginError: why turning it on or off was refused
    ///   - hotkey: whether the global hotkey works, or why it doesn't (APP-08)
    ///   - isRecordingShortcut: whether the shortcut recorder looks as if it records, for the gallery
    ///   - actions: what the buttons do
    ///   - linkRouting: the link router's switch; `nil` leaves it out
    public init(
        preferences: Binding<Preferences>, openAtLogin: Binding<Bool>, loginStatus: LoginItemStatus, loginError: String?,
        hotkey: HotkeyStatus = .off, isRecordingShortcut: Bool = false, actions: GeneralSettingsActions,
        linkRouting: LinkRoutingSwitch? = nil
    ) {
        _preferences = preferences
        self.openAtLogin = openAtLogin
        self.loginStatus = loginStatus
        self.loginError = loginError
        self.hotkey = hotkey
        self.isRecordingShortcut = isRecordingShortcut
        self.actions = actions
        self.linkRouting = linkRouting
    }

    public var body: some View {
        Form {
            SettingsPaneHeader(pane: .general)
            Section {
                OpenAtLoginRows(
                    isOn: openAtLogin, status: loginStatus, error: loginError,
                    openSystemSettings: actions.openLoginItemsSettings,
                    caption: nil)
            } header: {
                SettingsSectionHeader("Startup")
            } footer: {
                SettingsFooter("The menu bar item and its menu have a pane of their own: Menu Bar.")
            }
            Section {
                LabeledContent {
                    ShortcutRecorder(shortcut: $preferences.globalShortcut, isRecording: isRecordingShortcut)
                } label: {
                    SettingsRowLabel(
                        "Open the window with", "From any app; press it again to hide the window")
                }
                .settingsAnchor(.shortcut)
                if let problem = hotkey.problem {
                    StatusLine(.problem, problem)
                }
            } header: {
                SettingsSectionHeader("Keyboard")
            }
            Section {
                if let linkRouting {
                    Toggle(isOn: linkRouting.isOn) {
                        SettingsRowLabel(
                            "Open GitLab and Jenkins links in MegaMonitor",
                            "Other links go on to \(linkRouting.browserName); hold ⌥ to open any link there")
                    }
                    .settingsSwitch()
                    .settingsAnchor(.linkRouting)
                    .disabled(linkRouting.isChanging)
                    if let note = linkRouting.note {
                        StatusLine(.note, note)
                    }
                }
                Toggle(isOn: $preferences.fillInCopiedLink) {
                    SettingsRowLabel(
                        "Fill in a copied link",
                        "Watch a Build… starts with the link you copied")
                }
                .settingsSwitch()
            } header: {
                SettingsSectionHeader("Links")
            }
            Section {
                Toggle(isOn: $preferences.easterEggs) {
                    SettingsRowLabel("Easter eggs", "The butler sometimes has something to say")
                }
                .settingsSwitch()
            } header: {
                SettingsSectionHeader("Fun")
            }
        }
        .formStyle(.grouped)
        .revealsSettingsFields()
    }
}

/// Settings → Notifications' form: how a finished build alerts, stage banners, the permission row and the previews,
/// and the slot warning. It draws only what it is given.
public struct NotificationsSettingsForm: View {
    @Binding private var preferences: Preferences
    private let notification: NotificationNotice?
    private let canPreview: Bool
    private let actions: GeneralSettingsActions
    private let policy: NotificationPolicy
    private let setGroup: (NotificationPolicy.Group, Bool) -> Void
    private let resetJob: (String) -> Void
    private let inboxPermission: NotificationPermission?

    /// - Parameters:
    ///   - preferences: the preferences; a change saves at once
    ///   - notification: the notification row, if one shows
    ///   - canPreview: whether the team values are there, which the previews' links need (ALERT-07)
    ///   - actions: what the buttons do
    ///   - policy: which builds may alert: My Builds, Watching, and the jobs with a setting of their own (ALERT-09)
    ///   - setGroup: switches a group's alerts on or off
    ///   - resetJob: makes a job follow its group again, by job key
    ///   - inboxPermission: what macOS allows, for the Inbox's Desktop Notification choice; `nil` while it isn't known
    public init(
        preferences: Binding<Preferences>, notification: NotificationNotice?, canPreview: Bool,
        actions: GeneralSettingsActions, policy: NotificationPolicy = NotificationPolicy(),
        setGroup: @escaping (NotificationPolicy.Group, Bool) -> Void = { _, _ in },
        resetJob: @escaping (String) -> Void = { _ in }, inboxPermission: NotificationPermission? = nil
    ) {
        self.inboxPermission = inboxPermission
        self.policy = policy
        self.setGroup = setGroup
        self.resetJob = resetJob
        _preferences = preferences
        self.notification = notification
        self.canPreview = canPreview
        self.actions = actions
    }

    public var body: some View {
        Form {
            SettingsPaneHeader(pane: .notifications)
            Section {
                LabeledContent {
                    SwiftUI.Picker("When a build finishes", selection: $preferences.alertStyle) {
                        ForEach(Preferences.AlertStyle.allCases, id: \.self) { style in
                            Text(SettingsOptionTitles.alertStyle(style)).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    SettingsRowLabel(
                        "When a build finishes",
                        "The window stays until you close it; a banner goes away by itself")
                }
                .settingsAnchor(.buildAlerts)
                Toggle(isOn: $preferences.stageAlerts) {
                    SettingsRowLabel("Banner when a stage fails", "Before the build has finished")
                }
                .settingsSwitch()
                if let notification {
                    StatusLine(notification.kind, notification.text) {
                        Button(notification.buttonTitle) {
                            if notification.permission == .off {
                                actions.openNotificationSettings()
                            } else {
                                actions.turnOnNotifications()
                            }
                        }
                    }
                }
                LabeledContent {
                    HStack {
                        Button("Success") { actions.preview(.success) }
                        Button("Failure") { actions.preview(.failure) }
                    }
                    .disabled(!canPreview)
                } label: {
                    SettingsRowLabel(
                        "Preview", canPreview ? nil : "Needs a project first")
                }
            } header: {
                SettingsSectionHeader("Builds")
            }
            Section {
                Toggle(isOn: Binding(get: { policy.mine }, set: { setGroup(.mine, $0) })) {
                    SettingsRowLabel("My builds")
                }
                .settingsSwitch()
                .settingsAnchor(.mutedJobs)
                Toggle(isOn: Binding(get: { policy.watching }, set: { setGroup(.watching, $0) })) {
                    SettingsRowLabel("Watched builds")
                }
                .settingsSwitch()
                if policy.jobs.isEmpty {
                    Text("No job has a setting of its own. A build's Notifications menu mutes its job or always notifies.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(policy.jobs.keys.sorted(), id: \.self) { job in
                        JobNotificationRow(job: job, setting: policy.jobs[job] ?? .never) {
                            resetJob(job)
                        }
                    }
                }
            } header: {
                SettingsSectionHeader("Which Builds Alert")
            } footer: {
                SettingsFooter("Quiet builds stay in the lists and the menu bar; only their alerts and banners stop.")
            }
            InboxNotificationsSection(rules: $preferences.inboxNotifications, permission: inboxPermission, actions: actions)
            Section {
                Toggle(isOn: $preferences.slotAlerts) {
                    SettingsRowLabel(
                        "Warn before a code freeze",
                        "While your committed work items have no merged merge request")
                }
                .settingsSwitch()
                .settingsAnchor(.slotWarning)
            } header: {
                SettingsSectionHeader("Slots")
            }
        }
        .formStyle(.grouped)
        .revealsSettingsFields()
    }
}

/// A job with an alert setting of its own: its name, "Muted" or "Always", and Reset, which makes it follow its group.
private struct JobNotificationRow: View {
    let job: String
    let setting: NotificationPolicy.JobSetting
    let reset: () -> Void

    var body: some View {
        let parts = BuildID.split(jobKey: job)
        LabeledContent {
            HStack(spacing: 8) {
                Label(
                    setting == .never ? "Muted" : "Always",
                    systemImage: setting == .never ? "bell.slash.fill" : "bell.badge.fill")
                    .font(.callout)
                    .foregroundStyle(setting == .never ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                Button("Reset", action: reset)
                    .help("Follow My builds or Watched builds again")
            }
        } label: {
            SettingsRowLabel(Build.label(forJob: parts.job))
        }
    }
}

extension ChangesOutline {
    /// the preferences key of Settings → Appearance's "Folders in code changes": open instead of folded
    static let foldersOpenKey = "changes.foldersOpen"
}

/// Settings → Appearance's form: the details' width, the reading size, how code changes and discussions show. The
/// values are the same `@AppStorage` keys the View menu and the cards change in place, so both stay in step. Never
/// the colors yet (plan Task 7.10).
struct AppearanceSettingsForm: View {
    @AppStorage(MarkdownReadingSize.key) private var readingStep = MarkdownReadingSize.defaultStep
    @AppStorage("mergeRequestDiffLayout") private var diffLayout: DiffLayoutChoice = .inline
    @AppStorage(ChangesOutline.foldersOpenKey) private var foldersOpen = false
    @AppStorage(CommentThreadOrder.sortKey) private var commentSort: CommentThreadSort = .oldestFirst
    @AppStorage(CommentThreadOrder.openFirstKey) private var openFirst = true

    var body: some View {
        Form {
            SettingsPaneHeader(pane: .appearance)
            Section {
                ContentWidthRows()
                    .settingsAnchor(.contentWidth)
                Picker(selection: Binding(
                    get: { MarkdownReadingSize.clamped(readingStep) }, set: { readingStep = $0 }
                )) {
                    ForEach(MarkdownReadingSize.scales.indices, id: \.self) { step in
                        Text(verbatim: Self.percent(step)).tag(step)
                    }
                } label: {
                    SettingsRowLabel("Text size", "Of descriptions and comments")
                }
                .pickerStyle(.menu)
                .settingsAnchor(.textSize)
            } header: {
                SettingsSectionHeader("Reading")
            } footer: {
                SettingsFooter(
                    "The width limits how wide the cards of a merge request, work item or build get on a big window; "
                        + "lists, the sidebar and the toolbar keep theirs.")
            }
            Section {
                LabeledContent {
                    Picker("Layout", selection: $diffLayout) {
                        Text("Inline").tag(DiffLayoutChoice.inline)
                        Text("Side by Side").tag(DiffLayoutChoice.sideBySide)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    SettingsRowLabel("Layout")
                }
                .settingsAnchor(.diffLayout)
                LabeledContent {
                    Picker("Folders", selection: $foldersOpen) {
                        Text("Folded").tag(false)
                        Text("Open").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    SettingsRowLabel("Folders", "When a merge request touches several")
                }
            } header: {
                SettingsSectionHeader("Code Changes")
            }
            Section {
                Picker(selection: $commentSort) {
                    ForEach(CommentThreadSort.allCases, id: \.self) { sort in
                        Text(verbatim: sort.title).tag(sort)
                    }
                } label: {
                    SettingsRowLabel("Order", "By last activity")
                }
                .pickerStyle(.menu)
                .settingsAnchor(.discussions)
                Toggle(isOn: $openFirst) {
                    SettingsRowLabel("Open threads first")
                }
                .settingsSwitch()
            } header: {
                SettingsSectionHeader("Discussions")
            }
            SidebarOrderSection()
        }
        .formStyle(.grouped)
        .revealsSettingsFields()
    }

    /// "85%", "100% (Default)", "200%"
    private static func percent(_ step: Int) -> String {
        let text = "\(Int((MarkdownReadingSize.scales[step] * 100).rounded()))%"
        return MarkdownReadingSize.isDefault(step) ? text + " (Default)" : text
    }
}

/// Settings → General, from the settings store, with the login item's status read on appear and whenever the app
/// becomes active, since System Settings can change it at any time.
struct GeneralPane: View {
    let system: SettingsSystem
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = settings
        GeneralSettingsForm(
            preferences: $settings.preferences,
            openAtLogin: Binding(
                get: { settings.openAtLogin.isOn },
                set: { on in Task { await settings.setOpenAtLogin(on) } }),
            loginStatus: settings.openAtLogin, loginError: settings.openAtLoginError, hotkey: model.hotkey.status,
            actions: GeneralSettingsActions.of(settings: settings, model: model, system: system, permission: nil),
            linkRouting: system.linkRouting.map(linkRoutingSwitch))
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refresh()
            }
    }

    private func linkRoutingSwitch(_ routing: LinkRouting) -> LinkRoutingSwitch {
        LinkRoutingSwitch(
            isOn: Binding(get: { routing.isOn }, set: { on in Task { await routing.setEnabled(on) } }),
            browserName: routing.browserName, note: routing.note, isChanging: routing.isChanging)
    }

    private func refresh() {
        system.linkRouting?.refresh()
        settings.refreshOpenAtLogin()
    }
}

/// Settings → Notifications, from the settings store, with the notification permission read on appear and whenever
/// the app becomes active, since System Settings can change it at any time.
struct NotificationsPane: View {
    let system: SettingsSystem
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model
    @ViewState private var permission: NotificationPermission?

    var body: some View {
        @Bindable var settings = settings
        NotificationsSettingsForm(
            preferences: $settings.preferences,
            notification: NotificationNotice.of(permission, preferences: settings.preferences),
            canPreview: settings.missingTeamValues.isEmpty,
            actions: GeneralSettingsActions.of(
                settings: settings, model: model, system: system,
                permission: { permission = $0 }),
            policy: model.projects.notifications,
            setGroup: { model.setNotifications(for: $0, isOn: $1) },
            resetJob: { model.setNotifications(nil, forJob: $0) },
            inboxPermission: permission)
            .task {
                permission = await system.notificationPermission()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { permission = await system.notificationPermission() }
            }
    }
}

/// Settings → Appearance.
struct AppearancePane: View {
    var body: some View {
        AppearanceSettingsForm()
    }
}

/// Settings → Claude: the Claude section, or why there is none while `claude` isn't installed (AI-01).
struct ClaudePane: View {
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model, model.ai.isSettingsShown {
            Form {
                SettingsPaneHeader(pane: .claude)
                AISettingsSection()
            }
            .formStyle(.grouped)
            .revealsSettingsFields()
        } else {
            ContentUnavailableView {
                Label("Claude Code Isn't Installed", systemImage: "sparkles")
            } description: {
                Text("MegaMonitor uses your own Claude Code login. Install claude, then come back here.")
            }
        }
    }
}

extension GeneralSettingsActions {
    /// The actions from the stores: the system's settings, the permission prompt and the previews.
    ///
    /// - Parameters:
    ///   - permission: told the permission after the prompt; nil where nothing shows it
    static func of(
        settings: SettingsStore, model: AppModel, system: SettingsSystem,
        permission: (@MainActor (NotificationPermission) -> Void)?
    ) -> GeneralSettingsActions {
        GeneralSettingsActions(
            openLoginItemsSettings: { settings.openLoginItemsSettings() },
            openNotificationSettings: { system.openNotificationSettings() },
            turnOnNotifications: {
                Task {
                    await system.requestNotificationPermission()
                    let now = await system.notificationPermission()
                    permission?(now)
                }
            },
            preview: { sample in
                let announcer = AlertAnnouncer(effects: model.dependencies.effects, log: model.log)
                let team = settings.primaryTeam
                let preferences = settings.preferences
                Task {
                    await announcer.preview(sample, team: team, preferences: preferences)
                }
            })
    }
}

/// A section's footer: what a setting does when on, in `.secondary` (`docs/design/settings.md`, Shared components).
struct SettingsFooter: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// A mini switch, as a grouped form's single-row setting has it (`docs/design/settings.md`).
    func settingsSwitch() -> some View {
        toggleStyle(.switch)
            .controlSize(.mini)
    }
}
