import MenubarCore
import SwiftUI

/// Settings → General's Claude section (AI-01): one switch, off by default; with it on, the model, the effort and the
/// morning digest. Hidden entirely while `claude` isn't installed, and in the gallery.
struct AISettingsSection: View {
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model, model.ai.isSettingsShown {
            let ai = model.ai
            Section {
                Toggle("Use Claude", isOn: binding(ai, \.isEnabled))
                    .settingsSwitch()
                if ai.settings.isEnabled {
                    Picker("Default model", selection: binding(ai, \.model)) {
                        ForEach(ClaudeModel.allCases, id: \.self) { model in
                            Text(verbatim: model.shortName).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Effort", selection: binding(ai, \.effort)) {
                        ForEach(ClaudeEffort.allCases, id: \.self) { effort in
                            Text(verbatim: effort.title).tag(effort)
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle("Use My Claude Code Setup", isOn: binding(ai, \.useMySetup))
                        .settingsSwitch()
                    if ai.settings.useMySetup {
                        Toggle("Use My CLAUDE.md", isOn: binding(ai, \.useMyClaudeMd))
                            .settingsSwitch()
                        setupTools(ai)
                    }
                    Toggle("Write a morning digest", isOn: binding(ai, \.morningDigest))
                        .settingsSwitch()
                    if ai.settings.morningDigest {
                        DatePicker("At", selection: digestTime(ai), displayedComponents: .hourAndMinute)
                    }
                }
            } header: {
                Text("Claude")
                    .task(id: ai.settings.useMySetup && ai.settings.isEnabled) {
                        if ai.settings.useMySetup, ai.settings.isEnabled {
                            await ai.listSetup(force: false)
                        }
                    }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFooter(
                    "Claude explains failed builds, summarizes merge request discussions, writes a daily digest and "
                        + "opens Claude Code in a checkout. It runs your own Claude Code login (claude). "
                        + "Nothing is sent without a click, except the morning digest you turn on; the first "
                        + "answer of each kind shows what it sends. Tokens, cookies and keys are removed first. Effort is how "
                        + "long Claude thinks before it answers: higher is more thorough and slower.")
                    if ai.settings.isEnabled {
                        SettingsFooter(
                            "Use My Claude Code Setup, in the chats: loads your skills, plugins, commands and MCP servers. "
                                + "Claude may only use reading tools. Each MCP server you leave on adds its tools to every "
                                + "message, which makes the first one slower; only GitLab and Jenkins are on until you choose.")
                    }
                }
            }
        }
    }

    /// The MCP tools the chats may use: the listing's state with a button to list again, then one switch per server with
    /// how many reading tools it adds and about how many tokens they add to every message. The list is made when the
    /// setup goes on and once per app session.
    @ViewBuilder private func setupTools(_ ai: AIStore) -> some View {
        LabeledContent("MCP Servers") {
            HStack(spacing: 8) {
                switch ai.setupInventory {
                case .unknown, .loading:
                    ProgressView()
                        .controlSize(.small)
                    Text("Listing…")
                        .foregroundStyle(.secondary)
                case .ready(let inventory):
                    let groups = inventory.serverGroups
                    let on = groups.filter { $0.isOn(choices: ai.settings.mcpServerChoices) }
                    Text("\(on.count) of \(groups.count) on, about \(Self.tokens(on.reduce(0) { $0 + $1.estimatedTokens })) added to each message")
                        .foregroundStyle(.secondary)
                case .failed:
                    Text("Not listed: every MCP tool stays off")
                        .foregroundStyle(.secondary)
                }
                Button("Refresh") {
                    Task { await ai.listSetup(force: true) }
                }
                .disabled(ai.setupInventory == .loading)
            }
        }
        if case .ready(let inventory) = ai.setupInventory {
            ForEach(inventory.serverGroups) { group in
                Toggle(isOn: serverBinding(ai, group)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: group.name)
                        Text("\(group.readingCount) reading tools, about \(Self.tokens(group.estimatedTokens)), \(group.toolCount - group.readingCount) kept off")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .settingsSwitch()
            }
        }
        if case .failed(let message) = ai.setupInventory {
            StatusLine(.problem, message)
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
