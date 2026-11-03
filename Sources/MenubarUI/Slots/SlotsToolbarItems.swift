import MenubarCore
import SwiftUI

/// Slots' own toolbar item, in the section group next to Reload: one gear for the section's settings, "Slots Settings".
/// It opens Settings at the slot schedule, the weekdays of the release, the code freeze and early access, which the
/// gear next to each card's dates opened before (the user, 2026-11-03).
struct SlotsToolbarItems: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem {
            SlotsSettingsButton()
        }
    }
}

/// The button of ``SlotsToolbarItems``. Without a settings store or a router in the environment, as in the gallery, it
/// still draws and does nothing.
struct SlotsSettingsButton: View {
    @Environment(SettingsStore.self) private var settings: SettingsStore?
    @Environment(WindowRouter.self) private var router: WindowRouter?

    var body: some View {
        Button {
            settings?.reveal(.slotSchedule)
            router?.open(.settings(pane: SettingsField.slotSchedule.pane))
        } label: {
            Label("Slots Settings", systemImage: "gearshape")
        }
        .help("Slots Settings")
    }
}
