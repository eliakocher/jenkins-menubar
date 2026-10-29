import MenubarCore
import SwiftUI

/// Settings → Jenkins's form (`docs/design/settings-jenkins.md`): how often Jenkins is checked (SET-01), and when
/// finished builds hide by themselves (HIDE-02, HIDE-03). Pop-ups of fixed, ordered values; a change saves at once.
struct JenkinsSettingsForm: View {
    @Binding var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Picker("Check Jenkins every", selection: $preferences.checkIntervalSeconds) {
                    ForEach(Preferences.checkIntervalOptions, id: \.self) { seconds in
                        Text(SettingsOptionTitles.seconds(seconds)).tag(seconds)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                SettingsFooter(
                    "Checks pause while the Mac sleeps or is offline, run half as often in Low Power Mode, and wait "
                        + "longer after Jenkins was unreachable.")
            }
            Section {
                Picker("Hide successful builds after", selection: $preferences.hideSuccessfulAfter) {
                    ForEach(Preferences.hideSuccessfulOptions, id: \.self) { value in
                        Text(SettingsOptionTitles.hideAfter(value)).tag(value)
                    }
                }
                .pickerStyle(.menu)
                Picker("Hide failed builds after", selection: $preferences.hideFailedAfter) {
                    ForEach(Preferences.hideFailedOptions, id: \.self) { value in
                        Text(SettingsOptionTitles.hideAfter(value)).tag(value)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Hide the builds of merged merge requests", isOn: $preferences.hidesMergedBuilds)
                    .settingsSwitch()
            } header: {
                Text("Finished Builds")
            } footer: {
                SettingsFooter("“Failed” covers unstable, aborted and other results. Running builds never hide by time.")
            }
        }
        .formStyle(.grouped)
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
