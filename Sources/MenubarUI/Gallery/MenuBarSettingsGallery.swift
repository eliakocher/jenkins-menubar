#if DEBUG
import MenubarCore
import SwiftUI

/// Settings → Menu Bar with its preview, the preview alone for several layouts, and the pane with a reordered layout
/// (APP-11).
private struct MenuBarSettingsGalleryView: View {
    @ViewState var preferences: Preferences
    var sample = MenuBarPreview.Sample.busy

    var body: some View {
        MenuBarSettingsForm(preferences: $preferences, sample: sample)
            .settingsPaneFrame(estimate: 900)
    }
}

extension GalleryCatalog {
    /// A layout far from the default: the Inbox as a count first, reviews and the slot on, failed builds off, zero
    /// counts shown, the butler always; the pane reordered with a row off, one without a list, and compact.
    static var customMenuBarLayout: MenuBarLayout {
        var layout = MenuBarLayout()
        layout.moveParts(from: [5], to: 0)
        layout.setPart(.reviews, isOn: true)
        layout.setPart(.slot, isOn: true)
        layout.setPart(.successful, isOn: false)
        layout.inboxStyle = .count
        layout.butler = .always
        layout.moveRows(from: [2], to: 0)
        layout.updateRow(.inbox) { $0.isOn = false }
        layout.updateRow(.workItems) { $0.showsFlyout = false }
        layout.updateRow(.pipelines) { $0.flyoutRows = 5 }
        layout.paneWidth = .compact
        return layout
    }

    static var menuBarEntries: [GalleryEntry] {
        var custom = Preferences(menuBarLayout: customMenuBarLayout)
        custom.iconStyle = .color
        var zeros = MenuBarLayout()
        zeros.hidesZeroCounts = false
        zeros.butler = .never
        var countsOnly = MenuBarLayout()
        countsOnly.setPart(.problem, isOn: false)
        countsOnly.setPart(.inbox, isOn: false)
        let previewSize = CGSize(width: 560, height: 100)
        return [
            GalleryEntry(screen: "settings-menu-bar", state: "typical", size: CGSize(width: SettingsMetrics.width, height: 900)) { _ in
                MenuBarSettingsGalleryView(preferences: Preferences())
            },
            GalleryEntry(screen: "settings-menu-bar", state: "custom", size: CGSize(width: SettingsMetrics.width, height: 900)) { _ in
                MenuBarSettingsGalleryView(preferences: custom)
            },
            GalleryEntry(screen: "settings-menu-bar", state: "problem-sample", size: CGSize(width: SettingsMetrics.width, height: 900)) { _ in
                MenuBarSettingsGalleryView(preferences: Preferences(), sample: .problem)
            },
            GalleryEntry(screen: "menu-bar-preview", state: "default-busy", size: previewSize) { _ in
                preview(MenuBarLayout(), .monochrome, .busy)
            },
            GalleryEntry(screen: "menu-bar-preview", state: "default-quiet", size: previewSize) { _ in
                preview(MenuBarLayout(), .monochrome, .quiet)
            },
            GalleryEntry(screen: "menu-bar-preview", state: "custom-color", size: previewSize) { _ in
                preview(customMenuBarLayout, .color, .busy)
            },
            GalleryEntry(screen: "menu-bar-preview", state: "zeros-no-butler", size: previewSize) { _ in
                preview(zeros, .monochrome, .quiet)
            },
            GalleryEntry(screen: "menu-bar-preview", state: "counts-only-problem", size: previewSize) { _ in
                preview(countsOnly, .color, .problem)
            },
            GalleryEntry(screen: "menu-pane", state: "reordered", size: CGSize(width: 760, height: 470)) { f in
                MenuPaneGalleryView(data: f.menuPaneData, open: .pipelines, layout: customMenuBarLayout)
            },
        ]
    }
}

/// The preview alone, at the width it has in Settings.
@MainActor
private func preview(_ layout: MenuBarLayout, _ style: Preferences.IconStyle, _ sample: MenuBarPreview.Sample) -> some View {
    MenuBarPreview(layout: layout, style: style, sample: sample)
        .padding(16)
        .frame(width: 560)
}
#endif
