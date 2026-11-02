import SwiftUI

/// Pipelines' own toolbar items, in the section group: Watch a Build…, which only this section shows (the menu command
/// of the same name stays in the Builds menu everywhere). The gallery gives it no action.
struct PipelinesToolbarItems: ToolbarContent {
    let watchBuild: @MainActor () -> Void

    var body: some ToolbarContent {
        ToolbarItem {
            Button {
                watchBuild()
            } label: {
                Label("Watch a Build…", systemImage: "binoculars")
            }
            .help("Watch a Build")
        }
    }
}
