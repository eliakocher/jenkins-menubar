import MenubarCore
import SwiftUI

/// Settings → Claude's sections (AI-01): one switch, off by default; with it on, the model and effort, your Claude Code
/// setup and the morning digest. Hidden entirely while `claude` isn't installed, and in the gallery.
struct AISettingsSection: View {
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model, model.ai.isSettingsShown {
            let ai = model.ai
            Section {
                Toggle(isOn: binding(ai, \.isEnabled)) {
                    SettingsRowLabel(
                        "Use Claude",
                        "Explains failed builds, summarizes discussions, writes a digest and opens Claude Code in a checkout")
                }
                .settingsSwitch()
                .settingsAnchor(.claude)
            } header: {
                SettingsSectionHeader("Claude")
                    .task(id: ai.settings.useMySetup && ai.settings.isEnabled) {
                        if ai.settings.useMySetup, ai.settings.isEnabled {
                            await ai.listSetup(force: false)
                        }
                    }
            } footer: {
                SettingsFooter(
                    "It runs your own Claude Code login (claude). Nothing is sent without a click, except the morning "
                        + "digest you turn on; the first answer of each kind shows what it sends, with tokens, cookies and "
                        + "keys removed first.")
            }
            if ai.settings.isEnabled {
                Section {
                    Picker(selection: binding(ai, \.model)) {
                        ForEach(ClaudeModel.allCases, id: \.self) { model in
                            Text(verbatim: model.shortName).tag(model)
                        }
                    } label: {
                        SettingsRowLabel("Default model")
                    }
                    .pickerStyle(.menu)
                    .settingsAnchor(.claudeModel)
                    Picker(selection: binding(ai, \.effort)) {
                        ForEach(ClaudeEffort.allCases, id: \.self) { effort in
                            Text(verbatim: effort.title).tag(effort)
                        }
                    } label: {
                        SettingsRowLabel("Effort", "How long Claude thinks before it answers; higher is more thorough and slower")
                    }
                    .pickerStyle(.menu)
                } header: {
                    SettingsSectionHeader("Model")
                }
                Section {
                    Toggle(isOn: binding(ai, \.useMySetup)) {
                        SettingsRowLabel("Use my Claude Code setup", "Loads your skills, plugins, commands and MCP servers in the chats")
                    }
                    .settingsSwitch()
                    .settingsAnchor(.claudeSetup)
                    if ai.settings.useMySetup {
                        Toggle(isOn: binding(ai, \.useMyClaudeMd)) {
                            SettingsRowLabel("Use my CLAUDE.md", "Your CLAUDE.md files come along with the setup")
                        }
                        .settingsSwitch()
                        setupTools(ai)
                    }
                } header: {
                    SettingsSectionHeader("Your Claude Code Setup")
                } footer: {
                    if ai.settings.useMySetup {
                        SettingsFooter(
                            "Claude may only use reading tools. Each MCP server you leave on adds its tools to every "
                                + "message, which makes the first one slower; only GitLab and Jenkins are on until you choose.")
                    }
                }
                Section {
                    Toggle(isOn: binding(ai, \.morningDigest)) {
                        SettingsRowLabel("Write a morning digest", "Posted as a notification")
                    }
                    .settingsSwitch()
                    .settingsAnchor(.morningDigest)
                    if ai.settings.morningDigest {
                        DatePicker(selection: digestTime(ai), displayedComponents: .hourAndMinute) {
                            SettingsRowLabel("At")
                        }
                    }
                } header: {
                    SettingsSectionHeader("Morning Digest")
                }
            }
        }
    }

    /// The MCP tools the chats may use: the listing's state with a button to list again, then one switch per server with
    /// how many reading tools it adds and about how many tokens they add to every message. The list is made when the
    /// setup goes on and once per app session.
    @ViewBuilder private func setupTools(_ ai: AIStore) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if ai.setupInventory == .unknown || ai.setupInventory == .loading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Refresh") {
                    Task { await ai.listSetup(force: true) }
                }
                .disabled(ai.setupInventory == .loading)
            }
        } label: {
            SettingsRowLabel("MCP servers", setupSummary(ai))
        }
        if case .ready(let inventory) = ai.setupInventory {
            ForEach(inventory.serverGroups) { group in
                Toggle(isOn: serverBinding(ai, group)) {
                    SettingsRowLabel(
                        group.name,
                        "\(group.readingCount) reading tools, about \(Self.tokens(group.estimatedTokens)), \(group.toolCount - group.readingCount) kept off")
                }
                .settingsSwitch()
            }
        }
        if case .failed(let message) = ai.setupInventory {
            StatusLine(.problem, message)
        }
    }

    /// The listing's state in a line, for the MCP servers row.
    private func setupSummary(_ ai: AIStore) -> String {
        switch ai.setupInventory {
        case .unknown, .loading:
            return "Listing…"
        case .ready(let inventory):
            let groups = inventory.serverGroups
            let on = groups.filter { $0.isOn(choices: ai.settings.mcpServerChoices) }
            return "\(on.count) of \(groups.count) on, about \(Self.tokens(on.reduce(0) { $0 + $1.estimatedTokens })) added to each message"
        case .failed:
            return "Not listed: every MCP tool stays off"
        }
    }

    /// "9K tokens"
    static func tokens(_ count: Int) -> String {
        count < 1000 ? "\(count) tokens" : "\(Int((Double(count) / 1000).rounded()))K tokens"
    }

    private func serverBinding(_ ai: AIStore, _ group: McpServerGroup) -> Binding<Bool> {
        Binding(
            get: { group.isOn(choices: ai.settings.mcpServerChoices) },
            set: { value in
                var settings = ai.settings
                settings.mcpServerChoices[group.key] = value
                ai.update(settings)
            })
    }

    private func binding<Value>(_ ai: AIStore, _ path: WritableKeyPath<AISettings, Value>) -> Binding<Value> {
        Binding(
            get: { ai.settings[keyPath: path] },
            set: { value in
                var settings = ai.settings
                settings[keyPath: path] = value
                ai.update(settings)
            })
    }

    /// The digest's time as a date today, for the time picker.
    private func digestTime(_ ai: AIStore) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(byAdding: .minute, value: ai.settings.digestMinutes, to: Calendar.current.startOfDay(for: Date()))
                    ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                var settings = ai.settings
                settings.digestMinutes = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
                ai.update(settings)
            })
    }
}
