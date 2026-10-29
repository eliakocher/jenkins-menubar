#if DEBUG
import MenubarCore
import SwiftUI

/// The main window's content sizes in the gallery (`main-window.md`, Where it lives).
enum MainWindowGallerySize {
    /// the default size
    static let standard = CGSize(width: 1120, height: 720)
    /// the least size with the sidebar
    static let minimum = CGSize(width: 820, height: 480)
}

/// The whole main window as the gallery shows it: the shell from fixtures with no actions, spinners at once, and the
/// window's size fixed, since the split view would otherwise ask for its least size.
struct MainWindowGalleryView<Content: View, Detail: View>: View {
    /// the window's default content size
    nonisolated static var defaultSize: CGSize { MainWindowGallerySize.standard }
    /// the window's least content size with the sidebar
    nonisolated static var minimumSize: CGSize { MainWindowGallerySize.minimum }

    let model: MainWindowShellModel
    let section: MainWindowSection
    var searchText = ""
    var sidebarVisible = true
    var size: CGSize
    private let content: Content
    private let detail: Detail

    init(
        model: MainWindowShellModel, section: MainWindowSection, searchText: String = "", sidebarVisible: Bool = true,
        size: CGSize, @ViewBuilder content: () -> Content, @ViewBuilder detail: () -> Detail
    ) {
        self.model = model
        self.section = section
        self.searchText = searchText
        self.sidebarVisible = sidebarVisible
        self.size = size
        self.content = content()
        self.detail = detail()
    }

    var body: some View {
        MainWindowShell(
            model: model, section: .constant(section), searchText: .constant(searchText),
            columnVisibility: .constant(sidebarVisible ? .all : .doubleColumn), actions: .none
        ) {
            content
        } detail: {
            detail
        } sectionToolbar: {
            GallerySectionToolbar(section: section, filters: model.workItemFilters)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.panelSpinnerDelay, .zero)
    }
}

/// Group 1 of the toolbar from plain values: lane S's filter menu in Work Items, lane T's items in Activity.
struct GallerySectionToolbar: ToolbarContent {
    let section: MainWindowSection
    let filters: WorkItemFilters

    var body: some ToolbarContent {
        if section == .workItems {
            WorkItemsFilterToolbar(filters: filters)
        }
        if section == .activity {
            ActivityToolbarItems(isInspectorShown: .constant(false), showInFinder: {}, clear: {})
        }
    }
}

extension GalleryCatalog {
    /// One entry per state of `docs/design/main-window.md`, with each section's own views from fixtures.
    static var mainWindowEntries: [GalleryEntry] {
        let size = MainWindowGallerySize.standard
        let minimum = MainWindowGallerySize.minimum
        return [
            GalleryEntry(screen: "main-window", state: "pipelines", size: size) { f in
                PipelinesGalleryView(data: f.mainWindow(), selection: "MR-12")
            },
            GalleryEntry(screen: "main-window", state: "merge-requests", size: size) { f in
                MergeRequestsGalleryView(panel: f.mainWindow().panel, selection: URL(string: f.reviewRequestID))
            },
            GalleryEntry(screen: "main-window", state: "work-items", size: size) { f in
                WorkItemsGalleryView(state: f.mainWindowWorkItems(f.mainWindow()), selection: "group/subgroup/project#31")
            },
            GalleryEntry(screen: "main-window", state: "activity", size: size) { f in
                let log = f.activity.log(f.activity.typicalEntries(), checks: f.activity.checks())
                return ActivityGalleryView(
                    fixtures: f, log: log, selection: log.items.first.map { [$0.id] } ?? [], inspectorShown: true,
                    request: f.activity.timeoutRequest)
            },
            GalleryEntry(screen: "main-window", state: "no-selection", size: size) { f in
                PipelinesGalleryView(data: f.mainWindow())
            },
            GalleryEntry(screen: "main-window", state: "counts-zero", size: size) { f in
                PipelinesGalleryView(data: f.mainWindowCountsZero)
            },
            GalleryEntry(screen: "main-window", state: "many-items", size: size) { f in
                PipelinesGalleryView(data: f.mainWindowMany, selection: "MR-12")
            },
            GalleryEntry(screen: "main-window", state: "sidebar-collapsed", size: size) { f in
                PipelinesGalleryView(data: f.mainWindow(), selection: "MR-12", sidebarVisible: false)
            },
            GalleryEntry(screen: "main-window", state: "checking", size: size) { f in
                PipelinesGalleryView(data: f.mainWindow(isChecking: true), selection: "MR-12")
            },
            GalleryEntry(screen: "main-window", state: "loading", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(
                    hasLoaded: false, isChecking: true, lastChecked: false, mine: [], watched: [],
                    mergeRequests: PanelData.MergeRequests(), workItems: PanelData.WorkItems()))
            },
            GalleryEntry(screen: "main-window", state: "empty", size: size) { f in
                PipelinesGalleryView(data: f.mainWindow(mine: [], watched: [], emptyState: .noJobs(user: f.me)))
            },
            GalleryEntry(screen: "main-window", state: "search-results", size: size) { f in
                PipelinesGalleryView(data: f.mainWindow(), selection: "MR-12", query: "login")
            },
            GalleryEntry(screen: "main-window", state: "search-no-results", size: size) { f in
                PipelinesGalleryView(data: f.mainWindow(), query: "zzz")
            },
            GalleryEntry(screen: "main-window", state: "problem-markers", size: size) { f in
                let data = f.mainWindow(
                    problem: .unreachable(.jenkins),
                    mergeRequests: PanelData.MergeRequests(
                        list: f.mergeRequestsInAllSections, problem: .rejectedToken(.gitLab), lastLoadAt: f.minutesAgo(1)))
                return WorkItemsGalleryView(state: f.mainWindowWorkItems(data), selection: "group/subgroup/project#31")
            },
            GalleryEntry(screen: "main-window", state: "no-token", size: size) { f in
                PipelinesGalleryView(data: f.mainWindow(problem: .noToken(.jenkins), lastChecked: false, mine: [], watched: []))
            },
            GalleryEntry(screen: "main-window", state: "no-team-values", size: size) { f in
                PipelinesGalleryView(data: f.mainWindow(
                    problem: .teamValuesMissing, lastChecked: false, mine: [], watched: [], team: TeamValues()))
            },
            GalleryEntry(screen: "main-window", state: "offline", size: size) { f in
                PipelinesGalleryView(
                    data: f.mainWindow(problem: .offline, mine: [f.runningBuild, f.failedBuild], watched: []), selection: "MR-12")
            },
            GalleryEntry(screen: "main-window", state: "update-ready", size: size) { f in
                PipelinesGalleryView(data: f.mainWindow(update: .updateReady), selection: "MR-12")
            },
            GalleryEntry(screen: "main-window", state: "update-running", size: size) { f in
                PipelinesGalleryView(
                    data: f.mainWindow(update: .rebuilding(RebuildProgress(fraction: 0.4, step: "Compiling MenubarUI"))),
                    selection: "MR-12")
            },
            GalleryEntry(screen: "main-window", state: "update-failed", size: size) { f in
                PipelinesGalleryView(data: f.mainWindow(update: .failed(reason: "build.sh exited with status 1")), selection: "MR-12")
            },
            GalleryEntry(screen: "main-window", state: "minimum-size", size: minimum) { f in
                PipelinesGalleryView(data: f.mainWindow(), selection: "MR-12", size: minimum)
            },
            GalleryEntry(screen: "main-window", state: "long-titles", size: minimum) { f in
                WorkItemsGalleryView(
                    state: f.mainWindowWorkItems(f.mainWindow(workItems: f.longWorkItems, update: .updateReady)),
                    selection: "group/subgroup/project#31", size: minimum)
            },
        ]
    }
}
#endif
