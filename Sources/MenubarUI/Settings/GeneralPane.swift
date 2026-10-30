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

    /// - Parameters:
    ///   - isOn: the switch; Settings binds it to the login item's status
    ///   - status: the login item's status
    ///   - error: why the last change was refused
    ///   - openSystemSettings: opens System Settings → General → Login Items
    public init(
        isOn: Binding<Bool>, status: LoginItemStatus, error: String?,
        openSystemSettings: @escaping @MainActor () -> Void
    ) {
        self.isOn = isOn
        self.status = status
        self.error = error
        self.openSystemSettings = openSystemSettings
    }

    public var body: some View {
        Toggle("Open at login", isOn: isOn)
            .settingsSwitch()
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

/// Settings → General's form (`docs/design/settings-general.md`): open at login, the menu bar item and its icon, the
/// alert style, stage banners, the notification row and the previews. It draws only what it is given.
public struct GeneralSettingsForm: View {
    @Binding private var preferences: Preferences
    private let openAtLogin: Binding<Bool>
    private let loginStatus: LoginItemStatus
    private let loginError: String?
    private let notification: NotificationNotice?
    private let canPreview: Bool
    private let hotkey: HotkeyStatus
    private let isRecordingShortcut: Bool
    private let actions: GeneralSettingsActions
    private let linkRouting: LinkRoutingSwitch?

    /// - Parameters:
    ///   - preferences: the preferences; a change saves at once
    ///   - openAtLogin: the switch of the login item
    ///   - loginStatus: the login item's status
    ///   - loginError: why turning it on or off was refused
    ///   - notification: the notification row, if one shows
    ///   - canPreview: whether the team values are there, which the previews' links need (ALERT-07)
    ///   - hotkey: whether the global hotkey works, or why it doesn't (APP-08)
    ///   - isRecordingShortcut: whether the shortcut recorder looks as if it records, for the gallery
    ///   - actions: what the buttons do
    ///   - linkRouting: the link router's switch; `nil` leaves the section out
    public init(
        preferences: Binding<Preferences>, openAtLogin: Binding<Bool>, loginStatus: LoginItemStatus, loginError: String?,
        notification: NotificationNotice?, canPreview: Bool, hotkey: HotkeyStatus = .off,
        isRecordingShortcut: Bool = false, actions: GeneralSettingsActions,
        linkRouting: LinkRoutingSwitch? = nil
    ) {
        self.linkRouting = linkRouting
        _preferences = preferences
        self.openAtLogin = openAtLogin
        self.loginStatus = loginStatus
        self.loginError = loginError
        self.notification = notification
        self.canPreview = canPreview
        self.hotkey = hotkey
        self.isRecordingShortcut = isRecordingShortcut
        self.actions = actions
    }

    public var body: some View {
        Form {
            Section {
                OpenAtLoginRows(
                    isOn: openAtLogin, status: loginStatus, error: loginError,
                    openSystemSettings: actions.openLoginItemsSettings)
                Toggle("Show in menu bar", isOn: $preferences.showInMenuBar)
                    .settingsSwitch()
                Picker("Menu bar icon", selection: $preferences.iconStyle) {
                    ForEach(Preferences.IconStyle.allCases, id: \.self) { style in
                        Text(SettingsOptionTitles.iconStyle(style)).tag(style)
                    }
                }
                .pickerStyle(.menu)
                LabeledContent("Open the window with") {
                    ShortcutRecorder(shortcut: $preferences.globalShortcut, isRecording: isRecordingShortcut)
                }
                if let problem = hotkey.problem {
                    StatusLine(.problem, problem)
                }
            } footer: {
                SettingsFooter(
                    "Open at login starts MegaMonitor when you log in. Checks and alerts go on while the menu bar icon "
                        + "is hidden; open MegaMonitor again to get to its window. The shortcut opens the window from "
                        + "any app and hides it again when it is in front; it needs ⌘, ⌃ or ⌥. Esc cancels a recording, "
                        + "⌫ clears the shortcut.")
            }
            Section {
                // In a LabeledContent, so the radios sit at the trailing edge as the other values do (review
                // SETTINGS-GENERAL-01); the hidden label still names the group for VoiceOver.
                LabeledContent("Alert for finished builds") {
                    Picker("Alert for finished builds", selection: $preferences.alertStyle) {
                        ForEach(Preferences.AlertStyle.allCases, id: \.self) { style in
                            Text(SettingsOptionTitles.alertStyle(style)).tag(style)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                }
                Toggle("Show a banner as soon as a stage fails", isOn: $preferences.stageAlerts)
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
                LabeledContent("Preview") {
                    HStack {
                        Button("Success") { actions.preview(.success) }
                        Button("Failure") { actions.preview(.failure) }
                    }
                    .disabled(!canPreview)
                }
            } header: {
                Text("Build Alerts")
            } footer: {
                SettingsFooter(
                    "The alert window stays on screen until you dismiss it; a banner goes away by itself and waits in "
                        + "Notification Center." + (canPreview ? "" : " Preview needs the team values."))
            }
            Section {
                ContentWidthRows()
            } header: {
                Text("Layout")
            } footer: {
                SettingsFooter(
                    "Limits how wide the cards of a merge request, work item or build detail get on a big window; the "
                        + "content stays centered. Lists, the sidebar and the toolbar keep their width.")
            }
            Section {
                Toggle("Warn before a slot's code freeze", isOn: $preferences.slotAlerts)
                    .settingsSwitch()
            } header: {
                Text("Slots")
            } footer: {
                SettingsFooter(
                    "A banner, never a sound, a few days before a slot's code freeze while your committed work items have "
                        + "no merged merge request. The dates come from Settings → Projects.")
            }
            Section {
                Toggle("Fill in a copied link", isOn: $preferences.fillInCopiedLink)
                    .settingsSwitch()
            } header: {
                Text("Watch a Build")
            } footer: {
                SettingsFooter(
                    "When Watch a Build… opens with an empty field, it fills in a copied link or merge request number. "
                        + "macOS may ask whether MegaMonitor can paste, again after the app is rebuilt.")
            }
            if let linkRouting {
                Section {
                    Toggle("Open GitLab and Jenkins Links in MegaMonitor", isOn: linkRouting.isOn)
                        .settingsSwitch()
                        .disabled(linkRouting.isChanging)
                    if let note = linkRouting.note {
                        StatusLine(.note, note)
                    }
                } header: {
                    Text("Links")
                } footer: {
                    SettingsFooter(
                        "MegaMonitor becomes your default browser and passes every other link on to "
                            + "\(linkRouting.browserName); hold ⌥ to open any link in the browser.")
                }
            }
            // Claude, only while claude is installed (AI-01).
            AISettingsSection()
            Section {
                Toggle("Easter eggs", isOn: $preferences.easterEggs)
                    .settingsSwitch()
            } footer: {
                SettingsFooter("The butler sometimes has something to say. Off, MegaMonitor says only what it needs to.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings → General, from the settings store, with the login item's status and the notification permission read on
/// appear and whenever the app becomes active, since System Settings can change both at any time.
struct GeneralPane: View {
    let system: SettingsSystem
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model
    @ViewState private var permission: NotificationPermission?

    var body: some View {
        @Bindable var settings = settings
        GeneralSettingsForm(
            preferences: $settings.preferences,
            openAtLogin: Binding(
                get: { settings.openAtLogin.isOn },
                set: { on in Task { await settings.setOpenAtLogin(on) } }),
            loginStatus: settings.openAtLogin, loginError: settings.openAtLoginError,
            notification: NotificationNotice.of(permission, preferences: settings.preferences),
            canPreview: settings.missingTeamValues.isEmpty, hotkey: model.hotkey.status, actions: actions,
            linkRouting: system.linkRouting.map(linkRoutingSwitch))
            .task {
                await refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await refresh() }
            }
    }

    private var actions: GeneralSettingsActions {
        let settings = settings
        let model = model
        let system = system
        return GeneralSettingsActions(
            openLoginItemsSettings: { settings.openLoginItemsSettings() },
            openNotificationSettings: { system.openNotificationSettings() },
            turnOnNotifications: {
                Task {
                    await system.requestNotificationPermission()
                    permission = await system.notificationPermission()
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

    private func linkRoutingSwitch(_ routing: LinkRouting) -> LinkRoutingSwitch {
        LinkRoutingSwitch(
            isOn: Binding(get: { routing.isOn }, set: { on in Task { await routing.setEnabled(on) } }),
            browserName: routing.browserName, note: routing.note, isChanging: routing.isChanging)
    }

    private func refresh() async {
        system.linkRouting?.refresh()
        settings.refreshOpenAtLogin()
        permission = await system.notificationPermission()
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
