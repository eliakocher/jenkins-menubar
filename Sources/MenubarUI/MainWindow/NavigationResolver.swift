import Foundation
import MenubarCore

/// What the app knows of the places in the main window's history (WIN-08): whether the item is still there, and the
/// symbol and title the Back and Forward menus show. It reads the stores once, so a menu of 50 places is not 50 reads,
/// and the builds and checkouts only when a place asks for them: the window makes one at each update.
@MainActor
final class NavigationResolver {
    private let model: AppModel
    /// the jobs the Pipelines list shows, as ``PipelinesData/jobs`` has them, without making its rows
    private lazy var pipelineJobs: Set<String> = {
        let projects = model.projects
        guard projects.problem != .teamValuesMissing else {
            return []
        }
        let waiting = model.pipelines.watchedJobs.filter(\.isWaiting).map(\.watched.job)
        return Set(projects.myBuilds.map(\.jobKey) + projects.watchedBuilds.map(\.jobKey) + waiting)
    }()
    private lazy var workspaces = WorkspacesListModel(WorkspacesData(model, now: Date()))

    init(_ model: AppModel) {
        self.model = model
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
            return pipelineJobs.contains(item)
        case .mergeRequests:
            return model.mergeRequests.list.map { $0.mergeRequests.contains { $0.id.absoluteString == item } } ?? true
        case .workItems:
            return model.workItems.lists.map { $0.all.contains { $0.id == item } } ?? true
        case .workspaces:
            return workspaces.row(item) != nil
        case .slots:
            return item.isEmpty || (model.workItems.lists.map { $0.all.contains { $0.id == item } } ?? true)
                || model.slotItems.items.contains { $0.id == item }
        case .activity, .digest, .inbox:
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
            let found = model.mergeRequests.list.flatMap { list in (list.mergeRequests + list.merged).first { $0.id.absoluteString == item } }
            return found.map { "!\(String($0.iid)) \($0.title)" } ?? location.section.title
        case .workItems:
            let found = model.workItems.lists?.all.first { $0.id == item }
            return found.map { "\($0.iid.map { "#\($0)" } ?? $0.reference) \($0.displayTitle)" } ?? location.section.title
        case .workspaces:
            return URL(fileURLWithPath: item).lastPathComponent
        case .slots:
            let found = (model.slotItems.items + (model.workItems.lists?.all ?? [])).first { $0.id == item }
            return found.map { "\($0.iid.map { "#\($0)" } ?? $0.reference) \($0.displayTitle)" } ?? location.section.title
        case .activity, .digest, .inbox:
            return location.section.title
        }
    }
}
