#if DEBUG
import MenubarCore
import SwiftUI

extension GalleryCatalog {
    /// Settings → Hot Corners: off and empty, the corners imported from the old app, and the old app's warning.
    static var settingsHotCornersEntries: [GalleryEntry] {
        let imported = HotCornerSettings(
            enabled: true,
            topLeft: HotCornerSetup(plain: .system(.applicationWindows), option: .openSection(.pipelines)),
            topRight: HotCornerSetup(plain: .system(.missionControl), shift: .refreshNow),
            bottomLeft: HotCornerSetup(plain: .system(.desktop)),
            bottomRight: HotCornerSetup(
                delay: 0.5, plain: .runShortcut(name: "Caffeinate Claude"), command: .system(.lockScreen)))
        let shortcuts = ["Caffeinate Claude", "Toggle Dark Mode", "Start Focus "]

        func entry(
            _ state: String, _ settings: HotCornerSettings, legacy: Bool = false, selected: HotCorner = .topLeft,
            height: CGFloat = 900
        ) -> GalleryEntry {
            GalleryEntry(
                screen: "settings-hot-corners", state: state, size: CGSize(width: SettingsMetrics.width, height: height)
            ) { _ in
                HotCornersSettingsForm(
                    preferences: .constant(Preferences(hotCorners: settings)), isLegacyAppRunning: legacy,
                    shortcutNames: shortcuts, selected: selected
                )
                .settingsPaneFrame(estimate: height)
            }
        }

        return [
            entry("off", HotCornerSettings()),
            entry("imported", imported, selected: .bottomRight),
            entry("legacy-running", imported, legacy: true, selected: .bottomRight),
        ]
    }
}
#endif
