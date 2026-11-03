import AppKit
import MenubarCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Advanced's form: what rarely needs a change, the backup of the personal settings and the welcome flow.
/// It draws only what it is given.
struct AdvancedSettingsForm: View {
    @Binding var preferences: Preferences
    /// the result of the last export or import, under their buttons
    var backupResult: TeamFileResult?
    /// whether the welcome flow can be shown again; `false` hides that section
    var canShowWelcome = false
    var onExport: () -> Void = {}
    var onImport: () -> Void = {}
    var onShowWelcome: () -> Void = {}

    var body: some View {
        Form {
            SettingsPaneHeader(pane: .advanced)
            Section {
                Picker(selection: $preferences.gitLabMaxAgeSeconds) {
                    ForEach(Preferences.gitLabMaxAgeOptions, id: \.self) { seconds in
                        Text(SettingsOptionTitles.seconds(seconds)).tag(seconds)
                    }
                } label: {
                    SettingsRowLabel(
                        "Reload GitLab data older than",
                        "When a list shows them; Check Now always reloads. In the background, data refreshes every 5 min, or at "
                            + "this age if that is longer")
                }
                .pickerStyle(.menu)
                .settingsAnchor(.gitLabDataAge)
            } header: {
                SettingsSectionHeader("Data")
            }
            Section {
                LabeledContent {
                    HStack {
                        Button("Export…", action: onExport)
                        Button("Import…", action: onImport)
                    }
                } label: {
                    SettingsRowLabel(
                        "Back up my settings", "Your preferences, never your tokens or the team values")
                }
                .settingsAnchor(.backup)
                if let backupResult {
                    StatusLine(backupResult.kind, backupResult.text)
                }
            } header: {
                SettingsSectionHeader("Backup")
            }
            if canShowWelcome {
                Section {
                    LabeledContent {
                        Button("Show Welcome…", action: onShowWelcome)
                    } label: {
                        SettingsRowLabel("Show the welcome flow again")
                    }
                    .settingsAnchor(.welcome)
                } header: {
                    SettingsSectionHeader("Welcome")
                }
            }
        }
        .formStyle(.grouped)
        .revealsSettingsFields()
    }
}

/// Settings → Advanced, from the settings store. Export… saves the personal settings through a save panel sheet and
/// Import… reads them through a file importer; the app picks an import up at once.
struct AdvancedPane: View {
    let system: SettingsSystem
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model
    @ViewState private var isImporting = false
    @ViewState private var backupResult: TeamFileResult?

    var body: some View {
        @Bindable var settings = settings
        AdvancedSettingsForm(
            preferences: $settings.preferences, backupResult: backupResult,
            canShowWelcome: system.showWelcome != nil,
            onExport: export, onImport: { isImporting = true },
            onShowWelcome: { system.showWelcome?() })
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                importFile(result)
            }
    }

    private func importFile(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        do {
            let imported = try withSecurityScope(url) { try model.importPersonalSettings(from: url) }
            backupResult = TeamFileResult(
                kind: .ok, text: "Imported \(imported.count) values from \(url.lastPathComponent)")
        } catch let error as PersonalSettingsBackupError {
            backupResult = TeamFileResult(kind: .problem, text: error.message)
        } catch {
            backupResult = TeamFileResult(
                kind: .problem, text: "The settings could not be imported: \(error.localizedDescription)")
        }
    }

    /// Export… through the system's save panel, a sheet on Settings like the team file's.
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "megamonitor-settings.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let completion = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                exportFile(to: url)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func exportFile(to url: URL) {
        do {
            let count = try model.exportPersonalSettings(to: url)
            backupResult = TeamFileResult(kind: .ok, text: "Exported \(count) values to \(url.lastPathComponent)")
        } catch {
            backupResult = TeamFileResult(
                kind: .problem, text: "The backup could not be written: \(error.localizedDescription)")
        }
    }
}
