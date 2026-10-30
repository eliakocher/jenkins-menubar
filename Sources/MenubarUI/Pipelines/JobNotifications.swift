import MenubarCore
import SwiftUI

/// What a build row and the detail know of a job's notifications (ALERT-08): its own setting, and whether its group
/// alerts, which the "Default" entry names.
struct JobNotifications: Hashable, Sendable {
    /// the job key, which the setting is stored under
    var job = ""
    /// the job's setting; `nil` follows the group
    var setting: NotificationPolicy.JobSetting?
    /// whether the job's group alerts
    var groupIsOn = true

    init() {}

    init(_ policy: NotificationPolicy, job: String, group: NotificationPolicy.Group) {
        self.job = job
        setting = policy.jobs[job]
        groupIsOn = policy.isOn(group)
    }

    /// whether the job's alerts stay quiet, by its setting or its group
    var isMuted: Bool {
        setting == .never || (setting == nil && !groupIsOn)
    }

    /// the entry that follows the group: "Default (On)" or "Default (Off)"
    var defaultTitle: String {
        "Default (\(groupIsOn ? "On" : "Off"))"
    }
}

/// The bell at the end of a section header: on, or crossed out, with the tooltip that says what a click does.
struct NotificationsBell: View {
    let isOn: Bool
    /// "Watched Builds" or "My Builds"
    let subject: String
    let toggle: @MainActor () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isOn ? "bell" : "bell.slash")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Notifications \(isOn ? "On" : "Off") for \(subject)")
        .accessibilityLabel("Notifications for \(subject)")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// "Notifications for This Job": Default, Always Notify or Never Notify, as a submenu of the build's menus.
struct JobNotificationsMenu: View {
    let notifications: JobNotifications
    let set: @MainActor (NotificationPolicy.JobSetting?) -> Void

    var body: some View {
        Menu("Notifications for This Job") {
            Picker("Notifications for This Job", selection: selection) {
                Text(verbatim: notifications.defaultTitle).tag(NotificationPolicy.JobSetting?.none)
                Text("Always Notify").tag(NotificationPolicy.JobSetting?.some(.always))
                Text("Never Notify").tag(NotificationPolicy.JobSetting?.some(.never))
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private var selection: Binding<NotificationPolicy.JobSetting?> {
        Binding(get: { notifications.setting }, set: { set($0) })
    }
}

/// The small crossed-out bell on a row whose job is muted, by its setting or its group.
struct MutedMark: View {
    var body: some View {
        Image(systemName: "bell.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Notifications Off for This Job")
            .accessibilityLabel("Notifications off")
    }
}
