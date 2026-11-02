import MenubarCore
import SwiftUI

/// Settings → Jenkins's form (`docs/design/settings-jenkins.md`): how often Jenkins is checked (SET-01), and when
/// finished builds hide by themselves (HIDE-02, HIDE-03). Pop-ups of fixed, ordered values; a change saves at once.
struct JenkinsSettingsForm: View {
    @Binding var preferences: Preferences

    var body: some View {
        Form {
            SettingsPaneHeader(pane: .pipelines)
            Section {
                Picker(selection: $preferences.checkIntervalSeconds) {
                    ForEach(Preferences.checkIntervalOptions, id: \.self) { seconds in
                        Text(SettingsOptionTitles.seconds(seconds)).tag(seconds)
                    }
                } label: {
                    SettingsRowLabel(
                        "Check Jenkins every",
                        "Pauses while the Mac sleeps or is offline, runs half as often in Low Power Mode, and waits "
                            + "longer after Jenkins was unreachable")
                }
                .pickerStyle(.menu)
                .settingsAnchor(.checkInterval)
            } header: {
                SettingsSectionHeader("Checking")
            }
            Section {
                Picker(selection: $preferences.hideSuccessfulAfter) {
                    ForEach(Preferences.hideSuccessfulOptions, id: \.self) { value in
                        Text(SettingsOptionTitles.hideAfter(value)).tag(value)
                    }
                } label: {
                    SettingsRowLabel("Hide successful builds after", "Running builds never hide by time")
                }
                .pickerStyle(.menu)
                .settingsAnchor(.hideBuilds)
                Picker(selection: $preferences.hideFailedAfter) {
                    ForEach(Preferences.hideFailedOptions, id: \.self) { value in
                        Text(SettingsOptionTitles.hideAfter(value)).tag(value)
                    }
                } label: {
                    SettingsRowLabel(
                        "Hide failed builds after", "Failed also covers unstable, aborted and other results")
                }
                .pickerStyle(.menu)
                Toggle(isOn: $preferences.hidesMergedBuilds) {
                    SettingsRowLabel(
                        "Hide the builds of merged merge requests", "Also hides their running builds; branch builds always stay")
                }
                .settingsSwitch()
            } header: {
                SettingsSectionHeader("Finished Builds")
            }
        }
        .formStyle(.grouped)
        .revealsSettingsFields()
    }
}

/// Settings → Jenkins, from the settings store.
struct JenkinsPane: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        JenkinsSettingsForm(preferences: $settings.preferences)
    }
}
