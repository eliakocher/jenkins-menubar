#if DEBUG
import MenubarCore
import SwiftUI

/// The panel footer's group 1 alone, 420 pt wide with the panel's row style: the failure row first, then the offer or
/// the progress (`docs/design/update-row.md`, States).
private struct UpdateRowGalleryView: View {
    let state: UpdateState

    var body: some View {
        VStack(spacing: 0) {
            if case .failed(let reason) = state {
                UpdateFailureRow(text: UpdateText.failed(reason))
            }
            UpdateRow(state: state, rebuild: {})
        }
        .padding(.vertical, 6)
        .frame(width: PanelMetrics.width)
    }
}

extension GalleryCatalog {
    /// One entry per state of `docs/design/update-row.md`.
    static var updateRowEntries: [GalleryEntry] {
        func size(_ height: CGFloat) -> CGSize { CGSize(width: PanelMetrics.width, height: height) }
        let installed = URL(filePath: "/Users/jdoe/Applications/MegaMonitor.app", directoryHint: .isDirectory)
        return [
            GalleryEntry(screen: "update-row", state: "ready", size: size(50)) { _ in
                UpdateRowGalleryView(state: .updateReady)
            },
            GalleryEntry(screen: "update-row", state: "starting", size: size(90)) { _ in
                UpdateRowGalleryView(state: .rebuilding(.starting))
            },
            GalleryEntry(screen: "update-row", state: "progress", size: size(90)) { _ in
                // Long enough to be cut in the middle (review UPDATE-ROW-02).
                UpdateRowGalleryView(state: .rebuilding(RebuildProgress(
                    fraction: 0.45,
                    step: "Compiling MenubarUI Sources/MenubarUI/Welcome/Accounts/WelcomeAccountsStepView+Keychain.swift")))
            },
            GalleryEntry(screen: "update-row", state: "relaunching", size: size(90)) { _ in
                UpdateRowGalleryView(state: .installed(installed))
            },
            GalleryEntry(screen: "update-row", state: "failed", size: size(90)) { _ in
                UpdateRowGalleryView(state: .failed(reason: "build.sh exited with status 1"))
            },
            GalleryEntry(screen: "update-row", state: "failed-long", size: size(120)) { _ in
                // More than three lines, so the middle is cut (review UPDATE-ROW-02).
                UpdateRowGalleryView(state: .failed(
                    reason: "Sources/MenubarCore/Settings/SettingsStore.swift:123:45: error: cannot convert value of type "
                        + "'String' to expected argument type 'TeamValues.Key'; Sources/MenubarCore/Settings/"
                        + "SettingsStore.swift:131:12: error: value of type 'TeamValues' has no member 'jenkinsJobURLs'; "
                        + "build.sh exited with status 1"))
            },
        ]
    }
}
#endif
