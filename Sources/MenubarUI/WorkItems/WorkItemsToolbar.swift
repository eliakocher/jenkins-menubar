import MenubarCore
import SwiftUI

/// The Work Items section's toolbar items, group 1 of `docs/design/main-window.md`'s toolbar: the filter menu
/// (`line.3.horizontal.decrease`, WI-02). The main window shows them leading of the shared items while Work Items is
/// selected.
public struct WorkItemsToolbar: ToolbarContent {
    public init() {}

    public var body: some ToolbarContent {
        ToolbarItemGroup {
            WorkItemsFilterMenuFromSettings()
        }
    }
}

/// The toolbar's filter menu over plain values, for the gallery.
struct WorkItemsFilterToolbar: ToolbarContent {
    let filters: WorkItemFilters

    var body: some ToolbarContent {
        ToolbarItemGroup {
            WorkItemsFilterMenu(filters: .constant(filters)) {}
        }
    }
}

/// The filter menu, bound to the preferences in `SettingsStore`: a choice saves the preference, which logs it (SET-01)
/// and reloads the work items at once (WI-02, `AppModel`).
private struct WorkItemsFilterMenuFromSettings: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(WindowRouter.self) private var router

    var body: some View {
        WorkItemsFilterMenu(filters: WorkItemFilterItems.binding(settings)) {
            router.open(.settings(pane: .gitLab))
        }
    }
}

/// The toolbar's filter menu (`docs/design/work-items.md`, Toolbar filter menu): "Filter", with the items of
/// ``WorkItemFilterItems``.
struct WorkItemsFilterMenu: View {
    @Binding var filters: WorkItemFilters
    let openFilters: @MainActor () -> Void

    var body: some View {
        Menu {
            WorkItemFilterItems(filters: $filters, openFilters: openFilters)
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
        }
        .help("Filter the work items")
    }
}

/// The work item filters as menu items: Show, Type and State as inline pickers with a checkmark on the current value,
/// then "Filters…", which opens Settings → GitLab for the labels, the sort, the limit and the maximum age (WI-02,
/// SET-02). The toolbar's filter menu and View › Work Item Filters both show them.
public struct WorkItemFilterItems: View {
    @Binding private var filters: WorkItemFilters
    private let openFilters: @MainActor () -> Void

    /// - Parameters:
    ///   - filters: the work item filters; a choice writes them
    ///   - openFilters: opens Settings → GitLab
    public init(filters: Binding<WorkItemFilters>, openFilters: @escaping @MainActor () -> Void) {
        _filters = filters
        self.openFilters = openFilters
    }

    public var body: some View {
        Section("Show") {
            Picker("Show", selection: $filters.scope) {
                Text("Assigned to Me").tag(WorkItemFilters.Scope.assigned)
                Text("Created by Me").tag(WorkItemFilters.Scope.authored)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Section("Type") {
            Picker("Type", selection: $filters.type) {
                Text("All Types").tag(WorkItemFilters.TypeFilter.all)
                Text("Issues").tag(WorkItemFilters.TypeFilter.issue)
                Text("Tasks").tag(WorkItemFilters.TypeFilter.task)
                Text("Epics").tag(WorkItemFilters.TypeFilter.epic)
                Text("Incidents").tag(WorkItemFilters.TypeFilter.incident)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Section("State") {
            Picker("State", selection: $filters.state) {
                Text("Open").tag(WorkItemFilters.StateFilter.opened)
                Text("Closed").tag(WorkItemFilters.StateFilter.closed)
                Text("Open and Closed").tag(WorkItemFilters.StateFilter.all)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Divider()
        Button("Filters…") { openFilters() }
    }

    /// Returns a binding to the work item filters in the preferences: setting it saves them, which logs the change
    /// (SET-01) and reloads the work items (WI-02).
    ///
    /// - Parameter settings: the app's settings
    /// - Returns: the binding
    @MainActor
    public static func binding(_ settings: SettingsStore) -> Binding<WorkItemFilters> {
        Binding(
            get: { settings.preferences.workItems },
            set: { filters in
                var preferences = settings.preferences
                guard preferences.workItems != filters else {
                    return
                }
                preferences.workItems = filters
                settings.preferences = preferences
            })
    }
}
