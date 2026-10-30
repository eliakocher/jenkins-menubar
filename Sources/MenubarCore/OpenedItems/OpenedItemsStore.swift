import Foundation
import Observation

/// The merge requests, work items and Jenkins builds opened outside my lists, shown under "Opened" in the main window's
/// sidebar (WIN-06).
///
/// - Opening an item that is open already moves it to the top, and opening one adds it there.
/// - Items are kept in UserDefaults, as references and titles only; the items themselves load from GitLab when they are
///   shown, and stay in memory for a minute.
/// - An item that wasn't shown for seven days drops out when the app starts, unless it is pinned.
@Observable @MainActor
public final class OpenedItemsStore {
    /// the key in the preferences' suite
    static let defaultsKey = "openedItems"
    /// how long an item may go unshown before it drops out at launch
    public nonisolated static let expiresAfter: TimeInterval = 7 * 86400
    /// how long a loaded item is shown without asking again
    public nonisolated static let reusedFor: TimeInterval = 60

    /// the opened items, the one opened last first
    public private(set) var items: [OpenedItem]
    /// the state of each item's load
    public private(set) var states: [OpenedItem.ID: LoadState] = [:]
    /// the merge requests as loaded
    public private(set) var mergeRequests: [OpenedItem.ID: MergeRequest] = [:]
    /// the work items as loaded
    public private(set) var workItems: [OpenedItem.ID: WorkItem] = [:]
    /// the related merge requests of the loaded work items, when they could be asked
    public private(set) var related: [OpenedItem.ID: RelatedMergeRequestsCache.Entry] = [:]
    /// the builds as loaded, with their stages and test counts
    public private(set) var builds: [OpenedItem.ID: Build] = [:]

    /// How an item's load stands.
    public enum LoadState: Hashable, Sendable {
        case loading
        /// loaded at this time
        case loaded(Date)
        case failed(Problem)
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let services: GitLabServices?
    @ObservationIgnored private let pipelinesServices: PipelinesServices?
    @ObservationIgnored private let now: @Sendable () -> Date

    /// Reads the kept items and drops those that expired.
    ///
    /// - Parameters:
    ///   - defaults: the preferences' suite
    ///   - services: what loads a merge request or work item; `nil` loads none, as in the tests
    ///   - pipelines: what loads a build from Jenkins; `nil` loads none
    ///   - now: the clock
    public init(
        defaults: UserDefaults, services: GitLabServices? = nil, pipelines: PipelinesServices? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.services = services
        pipelinesServices = pipelines
        self.now = now
        let decoder = JSONDecoder()
        let kept = defaults.data(forKey: Self.defaultsKey).flatMap { try? decoder.decode([OpenedItem].self, from: $0) } ?? []
        let current = now()
        items = kept.filter { $0.isPinned || current.timeIntervalSince($0.lastViewedAt) < Self.expiresAfter }
        if items.count != kept.count {
            save()
        }
    }

    /// Returns an item.
    ///
    /// - Parameter id: the item's id
    public func item(_ id: OpenedItem.ID) -> OpenedItem? {
        items.first { $0.id == id }
    }

    /// Opens an item, or brings it to the top when it is open already.
    ///
    /// - Parameters:
    ///   - kind: merge request or work item
    ///   - project: the project's full path
    ///   - iid: the number in the project
    ///   - webURL: the item's page
    /// - Returns: the item's id
    @discardableResult
    public func open(kind: OpenedItem.Kind, project: String, iid: Int, webURL: URL) -> OpenedItem.ID {
        insert(OpenedItem(kind: kind, project: project, iid: iid, webURL: webURL, openedAt: now()))
    }

    /// Opens a Jenkins build, or brings it to the top when it is open already.
    ///
    /// - Parameters:
    ///   - project: the Team project whose Jenkins the build is on
    ///   - job: the build's job as in Jenkins URLs
    ///   - number: the build number
    ///   - webURL: the build's page
    /// - Returns: the item's id
    @discardableResult
    public func openBuild(project: ProjectID, job: String, number: Int, webURL: URL) -> OpenedItem.ID {
        insert(OpenedItem(kind: .build, project: project.rawValue, iid: number, webURL: webURL, openedAt: now(), job: job))
    }

    /// Notes that an item is shown, which restarts its seven days.
    ///
    /// - Parameter id: the item's id
    public func markViewed(_ id: OpenedItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        items[index].lastViewedAt = now()
        save()
    }

    /// Pins an item, which keeps it, or lets it expire again.
    ///
    /// - Parameters:
    ///   - id: the item's id
    ///   - pinned: whether it is kept
    public func setPinned(_ id: OpenedItem.ID, _ pinned: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isPinned != pinned else {
            return
        }
        items[index].isPinned = pinned
        save()
    }

    /// Closes an item and forgets what was loaded of it.
    ///
    /// - Parameter id: the item's id
    public func close(_ id: OpenedItem.ID) {
        items.removeAll { $0.id == id }
        forget(id)
        save()
    }

    /// Closes every item that isn't pinned.
    public func closeAll() {
        for item in items where !item.isPinned {
            forget(item.id)
        }
        items.removeAll { !$0.isPinned }
        save()
    }

    /// Loads an item for its detail: unless it loaded within the last minute or is loading. A failure keeps what was
    /// shown before. Cancelling the calling task doesn't cancel the request.
    ///
    /// - Parameters:
    ///   - id: the item's id
    ///   - force: asks again even for a fresh item, as Retry does
    public func load(_ id: OpenedItem.ID, force: Bool = false) async {
        guard let item = item(id), item.kind == .build ? pipelinesServices != nil : services != nil else {
            return
        }
        switch states[id] {
        case .loading:
            return
        case .loaded(let time) where !force && now().timeIntervalSince(time) < Self.reusedFor:
            return
        default:
            break
        }
        states[id] = .loading
        if item.kind == .build {
            await loadBuild(item)
            return
        }
        guard let services else {
            return
        }
        let result: Result<Loaded, GitLabError> = await Task {
            do {
                let client = try await services.session().get().client
                switch item.kind {
                case .mergeRequest:
                    return .success(.mergeRequest(try await client.send(.mergeRequest(project: item.project, iid: item.iid))))
                // A build never gets here: it loads above.
                case .workItem, .build:
                    let workItem = try await client.send(.workItem(project: item.project, iid: item.iid))
                    // A failure here only leaves the merge requests unknown; the item itself is there.
                    let related = await Self.related(of: workItem, client: client, now: services.now())
                    return .success(.workItem(workItem, related))
                }
            } catch let error as GitLabError {
                return .failure(error)
            } catch {
                return .failure(GitLabError(.unreachable(.gitLab)))
            }
        }.value
        // The item may have been closed while it loaded.
        guard self.item(id) != nil else {
            return
        }
        switch result {
        case .success(.mergeRequest(let mergeRequest)):
            mergeRequests[id] = mergeRequest
            setTitle(mergeRequest.title, of: id)
            states[id] = .loaded(now())
        case .success(.workItem(let workItem, let related)):
            workItems[id] = workItem
            self.related[id] = related
            setTitle(workItem.displayTitle, of: id)
            states[id] = .loaded(now())
        case .failure(let error):
            states[id] = .failed(error.problem)
        }
    }

    // MARK: - Private

    private func insert(_ opened: OpenedItem) -> OpenedItem.ID {
        let time = now()
        var item = opened
        if let index = items.firstIndex(where: { $0.id == opened.id }) {
            item = items.remove(at: index)
            item.openedAt = time
            item.lastViewedAt = time
        }
        items.insert(item, at: 0)
        save()
        return item.id
    }

    /// Loads a build: the build itself, the job's title and GitLab link, and the stages and test counts the detail shows.
    /// Only the build itself is needed; the rest is left out when Jenkins doesn't answer it.
    private func loadBuild(_ item: OpenedItem) async {
        let id = item.id
        guard let services = pipelinesServices, let job = item.job, let projectID = ProjectID(rawValue: item.project) else {
            states[id] = .failed(.teamValuesMissing)
            return
        }
        let project = services.team.project(projectID) ?? services.team.primaryProject()
        let number = item.iid
        let result: Result<Build, JenkinsError> = await Task {
            let token = await services.token(.jenkins)
            let client: JenkinsClient
            switch JenkinsClient.make(
                project: project, token: token, transport: services.recorder(for: project), timeouts: services.timeouts)
            {
            case .failure(let error): return .failure(error)
            case .success(let made): client = made
            }
            do {
                let last = try await client.build(job: job, number: number)
                let status = try? await client.job(job)
                var build = Build(
                    job: job, number: number, title: status?.title, gitLabURL: status?.gitLabURL, author: status?.author,
                    kind: .watched, phase: last.phase, startedAt: last.startedAt, estimatedDuration: last.estimatedDuration
                ).stamped(projectID)
                // As in the lists (PIPE-04), stages only for a build that runs or went wrong.
                if build.result == nil || build.result == .failure || build.result == .unstable {
                    build.stages = try? await client.stages(job: job, number: number)
                }
                build.testCounts = try? await client.testCounts(job: job, number: number)
                return .success(build)
            } catch let error as JenkinsError {
                return .failure(error)
            } catch {
                return .failure(JenkinsError(.unreachable(.jenkins)))
            }
        }.value
        // The item may have been closed while it loaded.
        guard self.item(id) != nil else {
            return
        }
        switch result {
        case .success(let build):
            builds[id] = build
            setTitle(build.title ?? build.label, of: id)
            states[id] = .loaded(now())
        case .failure(let error):
            states[id] = .failed(error.problem)
        }
    }

    private enum Loaded: Sendable {
        case mergeRequest(MergeRequest)
        case workItem(WorkItem, RelatedMergeRequestsCache.Entry?)
    }

    private static func related(of workItem: WorkItem, client: GitLabClient, now: Date) async -> RelatedMergeRequestsCache.Entry? {
        guard let operation = GitLabOperation.relatedMergeRequests(of: workItem),
            let mergeRequests = try? await client.send(operation)
        else {
            return nil
        }
        return RelatedMergeRequestsCache.Entry(workItemUpdatedAt: workItem.updatedAt, fetchedAt: now, mergeRequests: mergeRequests)
    }

    private func setTitle(_ title: String, of id: OpenedItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].title != title else {
            return
        }
        items[index].title = title
        save()
    }

    private func forget(_ id: OpenedItem.ID) {
        states[id] = nil
        mergeRequests[id] = nil
        workItems[id] = nil
        related[id] = nil
        builds[id] = nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
