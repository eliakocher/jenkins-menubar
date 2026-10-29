import AppKit
import MenubarCore
import SwiftUI

/// The Activity section (Task 5.5, LOG-04): the check times chart, the filters and the log, full width, with the
/// selected entry's details in an inspector on demand. The main window shows it in place of the content and detail
/// columns.
///
/// It reads the store from the environment and draws an ``ActivityContent`` from it.
/// - The window's search drives the store's: the root owns the field, and every change, the first value included, goes
///   to `ActivityStore.searchText`, which is never read back. The root clears the field when the section changes, so
///   the store gets an empty search the next time Activity shows.
/// - The level and source filters are the store's, which remembers them.
/// - While it shows, the store follows the files (`startFollowing`), so the list updates live; it stops on disappear.
/// - Entries that Clear or the rotation removed leave the selection; a restored one stays until the first read.
/// - It publishes ``ActivityCommands`` for the menu bar while it shows.
public struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(ActivityStore.self) private var store
    @Environment(WindowRouter.self) private var router
    @AppStorage("activity.chartExpanded") private var chartExpanded = true
    @ViewState private var hoveredTime: Date?
    @Binding private var selection: Set<ActivityItem.ID>
    @Binding private var isInspectorShown: Bool
    @Binding private var isConfirmingClear: Bool
    private let searchText: String

    /// - Parameters:
    ///   - selection: the selected log entries
    ///   - searchText: the window's search text; empty shows everything
    ///   - isInspectorShown: whether the inspector shows; the toolbar's toggle and View › Show Inspector share it
    ///   - isConfirmingClear: whether "Clear all activity?" shows; the toolbar's Clear Activity… shares it
    public init(
        selection: Binding<Set<ActivityItem.ID>>, searchText: String, isInspectorShown: Binding<Bool>,
        isConfirmingClear: Binding<Bool>
    ) {
        _selection = selection
        _isInspectorShown = isInspectorShown
        _isConfirmingClear = isConfirmingClear
        self.searchText = searchText
    }

    public var body: some View {
        ActivityContent(
            data: ActivityContentData(store: store), selection: $selection, level: levelBinding, source: sourceBinding,
            chartExpanded: $chartExpanded, hoveredTime: $hoveredTime, isInspectorShown: $isInspectorShown,
            isConfirmingClear: $isConfirmingClear, actions: actions, focusRequest: router.listFocusRequest
        ) {
            ActivityDetailView(selection: selection)
        }
        .onChange(of: searchText, initial: true) {
            store.searchText = searchText
        }
        .onChange(of: ActivitySelection.ItemsKey(store.items)) {
            let kept = ActivitySelection.pruned(selection, items: store.items, isLoaded: store.isLoaded)
            if kept != selection {
                selection = kept
            }
        }
        .onAppear {
            store.startFollowing()
        }
        .onDisappear {
            store.stopFollowing()
        }
        .focusedSceneValue(\.activityCommands, commands)
    }

    private var levelBinding: Binding<ActivityLevelFilter> {
        let store = store
        return Binding(get: { store.levelFilter }, set: { store.levelFilter = $0 })
    }

    private var sourceBinding: Binding<ActivityEntry.Source?> {
        let store = store
        return Binding(get: { store.sourceFilter }, set: { store.sourceFilter = $0 })
    }

    private var actions: ActivityActions {
        let store = store
        let model = model
        return ActivityActions(
            copyText: { ActivitySelection.copyText(of: $0, in: store) },
            checkNow: { model.checkNow() },
            showAllEntries: {
                store.levelFilter = .everything
                store.sourceFilter = nil
            },
            clear: { Task { await store.clear() } })
    }

    private var commands: ActivityCommands {
        let store = store
        let isInspectorShown = $isInspectorShown
        let isConfirmingClear = $isConfirmingClear
        return ActivityCommands(
            showInFinder: { ActivityFinder.show(store) },
            clear: { isConfirmingClear.wrappedValue = true },
            isInspectorShown: isInspectorShown.wrappedValue,
            toggleInspector: { isInspectorShown.wrappedValue.toggle() })
    }
}

/// The clipboard, for Copy and Copy as cURL.
enum ActivityPasteboard {
    /// Puts a text on the clipboard, in place of what it held.
    @MainActor
    static func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Show in Finder (LOG-04).
enum ActivityFinder {
    /// Selects the log file in Finder, or opens its folder when there is no file yet.
    @MainActor
    static func show(_ store: ActivityStore) {
        let target = store.finderTarget()
        if target.selectsFile {
            NSWorkspace.shared.activateFileViewerSelecting([target.url])
        } else {
            NSWorkspace.shared.open(target.url)
        }
    }
}
