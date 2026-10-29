import MenubarCore
import SwiftUI

/// Settings → General's Claude section (AI-01): one switch, off by default; with it on, the model, the monthly cap with
/// this month's spending, and the morning digest. Hidden entirely while `claude` isn't installed, and in the gallery.
struct AISettingsSection: View {
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model, model.ai.isSettingsShown {
            let ai = model.ai
            Section {
                Toggle("Use Claude", isOn: binding(ai, \.isEnabled))
                    .settingsSwitch()
                if ai.settings.isEnabled {
                    Picker("Model", selection: binding(ai, \.model)) {
                        ForEach(ClaudeModel.allCases, id: \.self) { model in
                            Text(verbatim: "\(model.title), \(model.typicalCost)").tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Monthly cap", selection: binding(ai, \.monthlyCapUSD)) {
                        ForEach(AISettings.capOptions, id: \.self) { cap in
                            Text(verbatim: "$\(cap)").tag(cap)
                        }
                    }
                    .pickerStyle(.menu)
                    StatusLine(.note, ai.monthLine)
                    Toggle("Write a morning digest", isOn: binding(ai, \.morningDigest))
                        .settingsSwitch()
                    if ai.settings.morningDigest {
                        DatePicker("At", selection: digestTime(ai), displayedComponents: .hourAndMinute)
                    }
                }
            } header: {
                Text("Claude")
            } footer: {
                SettingsFooter(
                    "Claude explains failed builds, summarizes merge request discussions, writes a daily digest and "
                        + "opens Claude Code in a checkout. It runs your own Claude Code login (claude), so the costs are "
                        + "yours. Nothing is sent without a click, except the morning digest you turn on; the first "
                        + "answer of each kind shows what it sends. Tokens, cookies and keys are removed first.")
            }
        }
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
