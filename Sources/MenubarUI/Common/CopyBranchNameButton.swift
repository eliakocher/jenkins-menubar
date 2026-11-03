import AppKit
import MenubarCore
import SwiftUI

/// "Copy Branch Name" for a work item's context menu: puts ``WorkItem/branchName``, like `18874-fix-closing-the-dialog`,
/// on the clipboard. An epic has no branch, so it shows nothing.
struct CopyBranchNameButton: View {
    let workItem: WorkItem

    var body: some View {
        if !workItem.isEpic, workItem.iid != nil {
            Button("Copy Branch Name") { Self.copy(workItem) }
        }
    }

    /// Puts a work item's branch name on the clipboard; the detail header's small button uses it too.
    @MainActor
    static func copy(_ workItem: WorkItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(workItem.branchName, forType: .string)
    }
}
