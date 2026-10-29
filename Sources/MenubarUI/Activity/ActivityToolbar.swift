import MenubarCore
import SwiftUI

/// The Activity section's toolbar items, group 1 of `docs/design/main-window.md`'s toolbar: Show in Finder, Clear
/// Activity… and the inspector's toggle. The filters sit in the section itself, as in the old Logs (LOG-04). The main
/// window shows them leading of the shared items while Activity is selected.
///
/// It reads the store from the environment and draws ``ActivityToolbarItems`` from it.
public struct ActivityToolbar: ToolbarContent {
    @Environment(ActivityStore.self) private var store
    @Binding private var isInspectorShown: Bool
    @Binding private var isConfirmingClear: Bool

    /// - Parameters:
    ///   - isInspectorShown: whether the inspector shows, shared with the section and View › Show Inspector
    ///   - isConfirmingClear: whether "Clear all activity?" shows, shared with the section and File › Clear Activity…
    public init(isInspectorShown: Binding<Bool>, isConfirmingClear: Binding<Bool>) {
        _isInspectorShown = isInspectorShown
        _isConfirmingClear = isConfirmingClear
    }

    public var body: some ToolbarContent {
        ActivityToolbarItems(isInspectorShown: $isInspectorShown, showInFinder: showInFinder) {
            // The section's one alert asks first, for the toolbar and the File menu alike (ACTIVITY-09).
            isConfirmingClear = true
        }
    }

    private func showInFinder() {
        ActivityFinder.show(store)
    }
}

/// The Activity toolbar items drawn from plain values, for the window and the gallery: symbols only, each with a
/// tooltip, and each also a menu command (File › Show in Finder, File › Clear Activity…, View › Show Inspector).
struct ActivityToolbarItems: ToolbarContent {
    @Binding var isInspectorShown: Bool
    let showInFinder: @MainActor () -> Void
    /// asks "Clear all activity?"
    let clear: @MainActor () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                showInFinder()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("Show the log file in Finder")
            Button {
                clear()
            } label: {
                Label("Clear Activity…", systemImage: "trash")
            }
            .help("Delete the log, the check times and the kept requests")
            Toggle(isOn: $isInspectorShown) {
                Label(isInspectorShown ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
            }
            .help(isInspectorShown ? "Hide the details" : "Show the details of the selected entry")
        }
    }
}
