import MenubarCore
import SwiftUI

/// What a build row and the detail know of a job's notifications (ALERT-09): its own setting, if it has one.
struct JobNotifications: Hashable, Sendable {
    /// the job key, which the setting is stored under
    var job = ""
    /// the job's setting; `nil` follows the table of Settings → Notifications
    var setting: NotificationPolicy.JobSetting?

    init() {}

    init(_ policy: NotificationPolicy, job: String) {
        self.job = job
        setting = policy.jobs[job]
    }

    /// whether the job's alerts stay quiet: it is set to Never
    var isMuted: Bool {
        setting == .never
    }

    /// the entry that follows the table
    var defaultTitle: String {
        "Default"
    }
}

/// "Notifications for This Job": Default, Always Notify or Never Notify, as a submenu of the build's menus, or as a
/// button of the detail's action row (`asButton`) that shows a bell, crossed out while the job is muted.
struct JobNotificationsMenu: View {
    let notifications: JobNotifications
    var asButton = false
    let set: @MainActor (NotificationPolicy.JobSetting?) -> Void

    var body: some View {
        if asButton {
            Menu {
                choices
            } label: {
                Label("Notifications", systemImage: notifications.isMuted ? "bell.slash" : "bell")
            }
            .menuIndicator(.hidden)
            .help("Notifications for This Job")
        } else {
            Menu("Notifications for This Job") {
                choices
            }
        }
    }

    private var choices: some View {
        Picker("Notifications for This Job", selection: selection) {
            Text(verbatim: notifications.defaultTitle).tag(NotificationPolicy.JobSetting?.none)
            Text("Always Notify").tag(NotificationPolicy.JobSetting?.some(.always))
            Text("Never Notify").tag(NotificationPolicy.JobSetting?.some(.never))
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private var selection: Binding<NotificationPolicy.JobSetting?> {
        Binding(get: { notifications.setting }, set: { set($0) })
    }
}

/// The small crossed-out bell on a row whose job is set to Never.
struct MutedMark: View {
    var body: some View {
        Image(systemName: "bell.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Notifications Off for This Job")
            .accessibilityLabel("Notifications off")
    }
}
