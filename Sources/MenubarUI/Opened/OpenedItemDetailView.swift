import MenubarCore
import SwiftUI

/// The detail of an item opened under "Opened" (WIN-06): the merge request's, work item's or build's normal detail, once
/// GitLab or Jenkins has answered for it, with a skeleton before (the reference and the title it knows, bars and cards for the
/// rest) and a message with Retry when it can't be loaded. The
/// detail views are the sections' own, so everything they offer, Claude included, works here too.
public struct OpenedItemDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    private let id: OpenedItem.ID

    /// - Parameter id: the opened item's id
    public init(id: OpenedItem.ID) {
        self.id = id
    }

    public var body: some View {
        content
            // A new selection of the item loads it again after a minute, as the sections' details do.
            .task(id: id) {
                model.opened.markViewed(id)
                await model.opened.load(id)
            }
    }

    @ViewBuilder
    private var content: some View {
        let store = model.opened
        if let item = store.item(id) {
            if let mergeRequest = store.mergeRequests[id] {
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    MergeRequestDetailContent(model: mergeRequestDetail(mergeRequest, at: context.date), actions: actions)
                }
                .workspaceTagsClickable()
            } else if let workItem = store.workItems[id] {
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    WorkItemDetailContent(model: workItemDetail(workItem, at: context.date), actions: actions)
                }
            } else if let build = store.builds[id] {
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    BuildDetailContent(model: buildDetail(build, at: context.date), actions: panelActions)
                }
                .workspaceTagsClickable()
            } else if case .failed(let problem)? = store.states[id] {
                OpenedItemFailure(item: item, problem: problem, actions: actions) {
                    Task { await store.load(id, force: true) }
                }
            } else {
                // What the app knows (the reference, maybe the title) at once; bars for the rest.
                OpenedItemSkeleton(item: item)
            }
        } else {
            Color.clear
        }
    }

    /// The app's actions; the pages open in the real browser, never through macOS, which would bring them back here.
    private var actions: GitLabSectionActions {
        GitLabSectionActions.live(model: model, router: router, openURL: openURL)
    }

    private var panelActions: PanelActions {
        PanelActions.mainWindow(model, router: router, openURL: openURL)
    }

    /// The build's detail as Pipelines shows a build, without what only a listed build has: Hide, Stop Watching and
    /// Rebuild belong to the lists' jobs.
    private func buildDetail(_ build: Build, at date: Date) -> BuildDetailModel? {
        let jobURL = model.team.project(build.project)?.team.jenkinsJob
        var row = BuildRowModel(build: build, now: date, jobURL: jobURL)
        row.offersRebuild = false
        row.rebuildWithChanges = nil
        var detail = BuildDetailModel(row: row, now: date)
        detail.canHide = false
        detail.canStopWatching = false
        detail.mergeRequest = model.mergeRequest(ofBuild: build)
        detail.workItems = model.workItems(ofBuild: build)
        return detail
    }

    private func mergeRequestDetail(_ mergeRequest: MergeRequest, at date: Date) -> MergeRequestDetailModel {
        var detail = MergeRequestDetailModel(MergeRequestsData(model, now: date), mergeRequest: mergeRequest)
        detail.workItems = model.workItems(ofMergeRequest: mergeRequest.reference, title: mergeRequest.title)
        if model.pipelines.preferences.easterEggs, let stats = detail.mergeRequest.diffStats {
            detail.eggLine = EggRules.diffLine(stats)
        }
        return detail
    }

    private func workItemDetail(_ workItem: WorkItem, at date: Date) -> WorkItemDetailModel {
        var data = WorkItemsData(model, now: date)
        // Its related merge requests came with the item, as the list's come with the list.
        if let entry = model.opened.related[id] {
            data.related.entries[workItem.reference] = entry
        }
        var detail = WorkItemDetailModel(data, workItem: workItem, reality: model.slotItem(of: workItem, now: date))
        if model.pipelines.preferences.easterEggs {
            detail.eggLine = EggRules.birthday(
                reference: data.shortReference(of: workItem), updatedAt: workItem.updatedAt, now: date)
        }
        return detail
    }
}

/// What the detail says when the item can't be loaded: why, and what to do about it.
private struct OpenedItemFailure: View {
    let item: OpenedItem
    let problem: Problem
    let actions: GitLabSectionActions
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(item.reference, systemImage: "exclamationmark.triangle")
        } description: {
            Text(verbatim: problem.message)
        } actions: {
            HStack {
                Button("Try Again", action: retry)
                if problem == .noToken(.gitLab) || problem == .rejectedToken(.gitLab) || problem == .missingScope {
                    Button("Open Settings…") { actions.openSettings(.accounts) }
                }
                Button(item.kind == .build ? "Open Build in Jenkins" : "Open in GitLab") { actions.open(item.webURL) }
            }
        }
    }
}

/// The page of an item that is still loading: the header with the reference and the title the app already has, and
/// the cards the page will have as skeletons, so the page keeps its shape when the item arrives.
struct OpenedItemSkeleton: View {
    let item: OpenedItem

    var body: some View {
        DetailPage(id: item.id) { _ in
            SkeletonHeader(reference: item.reference, title: item.title)
            CardColumnsLayout {
                switch item.kind {
                case .mergeRequest:
                    SkeletonCard(title: "Reviewers", symbol: "person.2", lines: 2)
                    SkeletonCard(title: "Approvals", symbol: "checkmark.seal", lines: 2)
                    SkeletonCard(title: "Description", symbol: "text.alignleft", lines: 5, width: .fullWidth)
                case .workItem:
                    SkeletonCard(title: "Merge Requests", symbol: "arrow.triangle.pull", lines: 3)
                    SkeletonCard(title: "Description", symbol: "text.alignleft", lines: 5, width: .fullWidth)
                    SkeletonCard(title: "Discussion", symbol: "bubble.left.and.bubble.right", lines: 5, width: .fullWidth)
                case .build:
                    SkeletonCard(title: "Stages", symbol: "list.bullet.indent", lines: 4)
                    SkeletonCard(title: "Failed Tests", symbol: "xmark.octagon", lines: 3)
                }
            }
        }
    }
}
