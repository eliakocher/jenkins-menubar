import AppKit
import MenubarCore
import SwiftUI

extension PanelActions {
    /// Returns the actions of the main window's rows and details: the panel's, without closing anything, since the
    /// window stays open (`main-window.md`, Row actions).
    ///
    /// - Parameters:
    ///   - model: the app's model
    ///   - router: the app's router
    ///   - openURL: the environment's action that opens a web page
    @MainActor
    static func mainWindow(_ model: AppModel, router: WindowRouter, openURL: OpenURLAction) -> PanelActions {
        PanelActions(
            open: { openURL($0) },
            openSettings: { router.open(.settings(pane: $0)) },
            openWindow: { router.open(.main) },
            watchBuild: { router.open(.watch(MergeRequestWatching.request(model: model, router: router))) },
            checkNow: { model.checkNow() },
            showHidden: { model.projects.unhideAll() },
            rebuild: {
                let updates = model.updates
                Task {
                    if let app = await updates.rebuild() {
                        router.onRebuilt?(app)
                    }
                }
            },
            quit: { NSApp.terminate(nil) },
            hide: { model.projects.hide($0) },
            stopWatching: { model.pipelines.unwatch($0) },
            copy: { MainWindowLinks.copy($0) },
            close: {},
            rebuildBuild: { model.projects.rebuild($0) },
            cancelRebuild: { job in
                let projects = model.projects
                Task { await projects.cancelRebuild(jobKey: job) }
            },
            watchBuilds: { MergeRequestWatching.watch($0, model: model, router: router) },
            newWorkItem: NewWorkItemLauncher.action(model: model) { openURL($0) })
    }
}

/// The selected row's link, for File › Open in Browser (⌘O) and Edit › Copy (⌘C) (`main-window.md`, Menu bar).
@MainActor
enum MainWindowLinks {
    /// Returns the link of the selected row of the shown section: the build's page (a waiting job: the job's), the
    /// merge request's or the work item's; `nil` without a selection, for a row that left the list, and in Activity,
    /// whose entries have no link.
    ///
    /// - Parameters:
    ///   - model: the app's model
    ///   - router: the router, which holds the section and the selections
    static func selected(_ model: AppModel, router: WindowRouter) -> URL? {
        let selection = router.selection
        switch router.section {
        case .pipelines:
            guard let job = selection.pipelines else {
                return nil
            }
            let data = PipelinesData(model, now: Date())
            switch data.item(job) {
            case .build(let row)?: return row.buildPage?.url
            case .waiting(let watched)?: return data.jobURL.map { PipelineRules.jobURL(job: watched.job, jobURL: $0) }
            case nil: return nil
            }
        case .mergeRequests:
            guard let id = selection.mergeRequests else {
                return nil
            }
            return model.mergeRequests.list?.mergeRequests.first { $0.id == id }?.webURL
        case .workItems:
            guard let id = selection.workItems else {
                return nil
            }
            return model.workItems.lists?.all.first { $0.id == id }?.webURL
        case .activity, .slots:
            return nil
        case .workspaces:
            // The checkout's merge request, else its work item (WS-04).
            let row = WorkspacesListModel(WorkspacesData(model, now: Date())).row(selection.workspaces)
            return row?.task.mergeRequest?.webURL ?? row?.task.workItemURL
        }
    }

    /// Puts a link on the clipboard.
    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}
