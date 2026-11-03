import MenubarCore
import SwiftUI

/// What Settings → Shortcuts says about a shortcut it didn't take: the command it was recorded for, the keys, and why.
/// A conflict waits for Replace or Cancel; macOS's own keys only say so.
public struct ShortcutNotice: Hashable, Sendable {
    public var commandID: String
    public var shortcut: HotkeyShortcut
    public var refusal: ShortcutRefusal

    public init(commandID: String, shortcut: HotkeyShortcut, refusal: ShortcutRefusal) {
        self.commandID = commandID
        self.shortcut = shortcut
        self.refusal = refusal
    }
}

/// Settings → Shortcuts' form (KEYS-01): the shortcut that opens MegaMonitor from anywhere, then every command of the
/// window's menus with its shortcut, a recorder to change or clear it, and Reset to Default per row and for all.
///
/// A shortcut another command has shows "Used by …" under the row, with Replace and Cancel (KEYS-02); the keys macOS
/// keeps are refused with a note. It draws only what it is given.
public struct ShortcutsSettingsForm: View {
    @Binding private var preferences: Preferences
    private let hotkey: HotkeyStatus
    private let recordingID: String?
    @ViewState private var notice: ShortcutNotice?
    /// the sidebar's order, which the section commands follow
    @AppStorage(SectionOrder.key) private var sectionOrder = ""

    /// - Parameters:
    ///   - preferences: the preferences; a change saves at once
    ///   - hotkey: whether the global hotkey works, or why it doesn't (APP-08)
    ///   - recordingID: the command whose recorder looks as if it records, for the gallery
    ///   - notice: a notice to start with, for the gallery
    public init(
        preferences: Binding<Preferences>, hotkey: HotkeyStatus = .off, recordingID: String? = nil, notice: ShortcutNotice? = nil
    ) {
        _preferences = preferences
        self.hotkey = hotkey
        self.recordingID = recordingID
        _notice = ViewState(initialValue: notice)
    }

    /// ⌘S, which Toggle Sidebar offers: nothing else in the app has it
    private static let commandS = HotkeyShortcut(keyCode: 1, modifiers: [.command], label: "S")

    public var body: some View {
        Form {
            SettingsPaneHeader(pane: .shortcuts)
            ForEach(ShortcutCommand.Group.allCases, id: \.self) { group in
                Section {
                    ForEach(ShortcutCatalog.commands(in: group).filter(hasSection)) { command in
                        rows(for: command)
                    }
                } header: {
                    SettingsSectionHeader(group.title)
                } footer: {
                    footer(for: group)
                }
            }
            Section {
                HStack {
                    Spacer(minLength: 0)
                    Button("Reset All to Default") {
                        notice = nil
                        preferences.shortcuts.resetAll()
                        preferences.globalShortcut = nil
                    }
                    .disabled(!hasChanges)
                }
                .settingsAnchor(.resetShortcuts)
            } footer: {
                SettingsFooter(
                    "macOS keeps ⌘Q, ⌘W, ⌘H, ⌘M and ⌘, for itself, and text fields keep ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z. "
                        + "⌘← and ⌘→ also go back and forward, whatever Back and Forward have.")
            }
        }
        .formStyle(.grouped)
        .revealsSettingsFields()
    }

    // MARK: Rows

    @ViewBuilder
    private func rows(for command: ShortcutCommand) -> some View {
        let name = title(of: command)
        LabeledContent {
            HStack(spacing: 6) {
                ShortcutRecorder(
                    shortcut: binding(for: command), isRecording: recordingID == command.id, name: name,
                    reservesClearButton: true)
                resetButton(for: command)
            }
        } label: {
            SettingsRowLabel(name, caption(of: command))
        }
        .settingsAnchor(.shortcut, enabled: command.id == ShortcutCatalog.globalID)
        .settingsAnchor(.sidebarShortcut, enabled: command.id == ShortcutCatalog.toggleSidebarID)
        if command.id == ShortcutCatalog.globalID, let problem = hotkey.problem {
            StatusLine(.problem, problem)
        }
        if let notice, notice.commandID == command.id {
            noticeRow(notice)
        } else if command.id == ShortcutCatalog.toggleSidebarID, let commandS = Self.commandS,
            !(preferences.shortcut(for: command.id)?.isSameKey(as: commandS) ?? false)
        {
            StatusLine(.note, "Nothing in MegaMonitor uses ⌘S.") {
                Button("Use ⌘S") { attempt(commandS, for: command) }
            }
        }
    }

    private func noticeRow(_ notice: ShortcutNotice) -> some View {
        let text: String
        switch notice.refusal {
        case .reserved(let note): text = note
        case .usedBy: text = "\(notice.shortcut.display) · \(notice.refusal.message)"
        }
        return StatusLine(notice.refusal.isReserved ? .problem : .note, text) {
            HStack(spacing: 8) {
                if notice.refusal.isReserved {
                    Button("OK") { self.notice = nil }
                } else {
                    Button("Replace") {
                        preferences.assign(notice.shortcut, to: notice.commandID)
                        self.notice = nil
                    }
                    Button("Cancel") { self.notice = nil }
                }
            }
        }
    }

    /// The arrow that gives a command its default again, which keeps its place while there is nothing to reset.
    private func resetButton(for command: ShortcutCommand) -> some View {
        let isCustomized = command.id != ShortcutCatalog.globalID && preferences.isShortcutCustomized(command.id)
        return Button {
            if notice?.commandID == command.id { notice = nil }
            preferences.shortcuts.reset(command.id)
        } label: {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Reset to Default" + (command.defaultShortcut.map { " (\($0.display))" } ?? ""))
        .accessibilityLabel("Reset \(command.title) to Default")
        .opacity(isCustomized ? 1 : 0)
        .disabled(!isCustomized)
    }

    @ViewBuilder
    private func footer(for group: ShortcutCommand.Group) -> some View {
        switch group {
        case .anywhere:
            SettingsFooter("It works from every app, so it needs ⌘, ⌃ or ⌥.")
        case .sections:
            SettingsFooter("They follow the sidebar's order (Appearance → Sidebar), so the first one is the first section.")
        default:
            EmptyView()
        }
    }

    // MARK: Values

    private var hasChanges: Bool {
        !preferences.shortcuts.isEmpty || preferences.globalShortcut != nil
    }

    /// whether a section command has a section in its place of the sidebar; the other commands always do
    private func hasSection(_ command: ShortcutCommand) -> Bool {
        guard let number = ShortcutCatalog.sectionNumber(of: command.id) else { return true }
        return number <= SectionOrder.merged(stored: sectionOrder).count
    }

    /// the row's name: the section commands say which section they show now
    private func title(of command: ShortcutCommand) -> String {
        guard let number = ShortcutCatalog.sectionNumber(of: command.id),
            let section = SectionOrder.merged(stored: sectionOrder)[safe: number - 1]
        else {
            return command.title
        }
        return "Show \(section.title)"
    }

    private func caption(of command: ShortcutCommand) -> String? {
        ShortcutCatalog.sectionNumber(of: command.id) == nil ? command.detail : nil
    }

    private func binding(for command: ShortcutCommand) -> Binding<HotkeyShortcut?> {
        Binding(
            get: { preferences.shortcut(for: command.id) },
            set: { new in
                guard let new else {
                    if notice?.commandID == command.id { notice = nil }
                    preferences.assign(nil, to: command.id)
                    return
                }
                attempt(new, for: command)
            })
    }

    /// Takes a recorded shortcut when it is free, and otherwise says why not under the row.
    private func attempt(_ shortcut: HotkeyShortcut, for command: ShortcutCommand) {
        if let refusal = preferences.shortcutRefusal(of: shortcut, for: command.id) {
            notice = ShortcutNotice(commandID: command.id, shortcut: shortcut, refusal: refusal)
        } else {
            notice = nil
            preferences.assign(shortcut, to: command.id)
        }
    }
}

extension ShortcutRefusal {
    /// whether macOS keeps the keys, which no Replace changes
    var isReserved: Bool {
        if case .reserved = self { return true }
        return false
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Settings → Shortcuts, from the settings store.
struct ShortcutsPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = settings
        ShortcutsSettingsForm(preferences: $settings.preferences, hotkey: model.hotkey.status)
    }
}
