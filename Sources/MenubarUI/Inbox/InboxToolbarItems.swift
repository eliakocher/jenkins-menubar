import MenubarCore
import SwiftUI

/// The Inbox's own toolbar item, in the section group next to Reload, as Slots has it: one gear, "Inbox Settings". It opens
/// Settings → Notifications at the Inbox's part: what each kind of event does (Pop-up, Desktop Notification, Inbox Only),
/// the badge, the coffee break and the order of the groups (the user, 2026-11-03: "in the inbox somewhere we need a
/// settings icon that jumps to its settings").
struct InboxToolbarItems: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem {
            InboxSettingsButton()
        }
    }
}

/// The button of ``InboxToolbarItems``. Without a settings store or a router in the environment, as in the gallery, it
/// still draws and does nothing.
struct InboxSettingsButton: View {
    @Environment(SettingsStore.self) private var settings: SettingsStore?
    @Environment(WindowRouter.self) private var router: WindowRouter?

    var body: some View {
        Button {
            settings?.reveal(.inboxNotifications)
            router?.open(.settings(pane: SettingsField.inboxNotifications.pane))
        } label: {
            Label("Inbox Settings", systemImage: "gearshape")
        }
        .help("Inbox Settings")
    }
}
