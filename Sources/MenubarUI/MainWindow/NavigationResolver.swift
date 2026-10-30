import Foundation
import MenubarCore

/// What the app knows of the places in the main window's history (WIN-08): whether the item is still there, and the
/// symbol and title the Back and Forward menus show. It reads the stores once, so a menu of 50 places is not 50 reads.
@MainActor
struct NavigationResolver {
    private let model: AppModel
    private let pipelines: PipelinesData
    private let workspaces: WorkspacesListModel

    init(_ model: AppModel) {
        self.model = model
        pipelines = PipelinesData(model, now: Date())
        workspaces = WorkspacesListModel(WorkspacesData(model, now: Date()))
    }

    /// Returns whether a place can be shown again: an item under "Opened" that is still open, a row that is still in
    /// its list. A list that didn't load yet has no say, so its rows count as there.
    func exists(_ location: NavigationLocation) -> Bool {
        if let id = location.opened {
            return model.opened.item(id) != nil
        }
        guard let item = location.item else {
            return true
        }
        switch location.section {
        case .pipelines:
            return pipelines.item(item) != nil
        case .mergeRequests:
            return model.mergeRequests.list.map { $0.mergeRequests.contains { $0.id.absoluteString == item } } ?? true
        case .workItems:
            return model.workItems.lists.map { $0.all.contains { $0.id == item } } ?? true
        case .workspaces:
            return workspaces.row(item) != nil
        case .activity, .slots:
            return true
        }
    }

    /// Returns the SF Symbol of a place: its section's, or its kind's under "Opened".
    func systemImage(_ location: NavigationLocation) -> String {
        guard let id = location.opened, let item = model.opened.item(id) else {
            return location.section.systemImage
        }
        switch item.kind {
        case .mergeRequest: return MainWindowSection.mergeRequests.systemImage
        case .workItem: return MainWindowSection.workItems.systemImage
        case .build: return MainWindowSection.pipelines.systemImage
        }
    }

    /// Returns the title of a place: the item's, with its reference where it has one, else the section's.
    func title(_ location: NavigationLocation) -> String {
        if let id = location.opened {
            guard let item = model.opened.item(id) else {
                return "Opened Item"
            }
            return "\(item.shortReference) \(item.title ?? item.fallbackTitle)"
        }
        guard let item = location.item else {
            return location.section.title
        }
        switch location.section {
        case .pipelines:
            return "\(location.section.title) \(Build.label(forJob: item.split(separator: "/").last.map(String.init) ?? item))"
        case .mergeRequests:
            let found = model.mergeRequests.list?.mergeRequests.first { $0.id.absoluteString == item }
            return found.map { "!\(String($0.iid)) \($0.title)" } ?? location.section.title
        case .workItems:
            let found = model.workItems.lists?.all.first { $0.id == item }
            return found.map { "\($0.iid.map { "#\($0)" } ?? $0.reference) \($0.displayTitle)" } ?? location.section.title
        case .workspaces:
            return URL(fileURLWithPath: item).lastPathComponent
        case .activity, .slots:
            return location.section.title
        }
    }
}
