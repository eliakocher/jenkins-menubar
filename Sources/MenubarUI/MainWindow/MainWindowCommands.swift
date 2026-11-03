import AppKit
import MenubarCore
import SwiftUI

/// The main window's section while the window is key; `nil` while another window is.
struct MainWindowFocusedSectionKey: FocusedValueKey {
    typealias Value = MainWindowSection
}

extension FocusedValues {
    /// the main window's section while the main window is key (`MainWindowRoot` sets it); `nil` otherwise
    var mainWindowSection: MainWindowSection? {
        get { self[MainWindowFocusedSectionKey.self] }
        set { self[MainWindowFocusedSectionKey.self] = newValue }
    }
}

/// The menu bar's commands for the main window (`docs/design/main-window.md`, Keyboard; WIN-05): Rebuild and Relaunch
/// in the app menu, New Work Item… (⌘N), Open in Browser (⌘O), Find… (⌘F), Activity's inspector (⌃⌘I), the sections (⌘1 and on), the
/// Builds menu (⌘R, ⌘L, the hidden builds, the selected build's commands), the window (⌘0), the reading size of descriptions (View ›
/// Make Text Bigger ⌘+, Smaller ⌘−, Actual Size ⌘0 while the main window is key) and no help book.
///
/// Edit › Copy (⌘C) is the window's own (`onCopyCommand`), so text fields keep theirs. Commands that open the window go
/// through the router, and so through the activation helper. While the Watch a Build… sheet is up, the section, watch
/// and open commands are off; Check Now and Settings work.
public struct MainWindowCommands: Commands {
    private let model: AppModel
    private let router: WindowRouter
    private let handOver: (@MainActor (OpenWindowAction, OpenSettingsAction) -> Bool)?
    @FocusedValue(\.mainWindowSection) private var focusedSection
    @FocusedValue(\.activityCommands) private var activityCommands
    /// the reading size of rendered Markdown (WIN-02), in the same preferences the views' `@AppStorage` use
    @AppStorage(MarkdownReadingSize.key) private var readingSizeStep = MarkdownReadingSize.defaultStep
    /// the sidebar's order of the sections, which ⌘1 and on follow (WIN-01)
    @AppStorage(SectionOrder.key) private var sectionOrder = ""

    /// - Parameters:
    ///   - model: the app's model
    ///   - router: the app's one router
    ///   - handOver: takes SwiftUI's window actions from the Window menu's "MegaMonitor" command whenever it runs,
    ///     and returns whether a window waited for them, which the command then doesn't follow with the main window.
    ///     The app performs that command itself while no view has handed the actions over yet (APP-03).
    public init(
        model: AppModel, router: WindowRouter,
        handOver: (@MainActor (OpenWindowAction, OpenSettingsAction) -> Bool)? = nil
    ) {
        self.model = model
        self.router = router
        self.handOver = handOver
        _readingSizeStep = AppStorage(
            wrappedValue: MarkdownReadingSize.defaultStep, MarkdownReadingSize.key, store: model.dependencies.preferences)
        _sectionOrder = AppStorage(wrappedValue: "", SectionOrder.key, store: model.dependencies.preferences)
    }

    /// Opens the About window, or brings it forward, with the credits as the easter eggs setting has them.
    private func showAbout() {
        AboutWindow.show(eggs: model.pipelines.preferences.easterEggs, model: model)
    }

    public var body: some Commands {
        // Toggle Sidebar replaces Apple's SidebarCommands, whose ⌃⌘S can't change: this one asks the window in front
        // to toggle its sidebar, as theirs does, and has the shortcut of Settings → Shortcuts (KEYS-01).
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(shortcut(ShortcutCatalog.toggleSidebarID))
        }
        // The About window: the butler's CC BY-SA attribution and the author's credit always, the roll of gags with the
        // easter eggs on (EGG-21).
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppIdentity.displayName)") {
                showAbout()
            }
        }
        CommandGroup(after: .appSettings) {
            Button("Rebuild and Relaunch") {
                let updates = model.updates
                let router = router
                Task {
                    if let app = await updates.rebuild() {
                        router.onRebuilt?(app)
                    }
                }
            }
            .disabled(!model.updates.offersRebuild)
        }
        CommandGroup(replacing: .newItem) {
            // GitLab's own new issue page in the browser, prefilled from the URL: no form here, no write (NEW-01).
            Button("New Work Item…") {
                openNewWorkItem(.blank(.task))
            }
            .keyboardShortcut(shortcut("newWorkItem"))
            .disabled(sheetIsUp || !NewWorkItemLauncher.canOpen(model))
            Menu("New Work Item As") {
                ForEach(WorkItemKind.allCases, id: \.self) { kind in
                    Button(kind.title) { openNewWorkItem(.blank(kind)) }
                }
            }
            .disabled(sheetIsUp || !NewWorkItemLauncher.canOpen(model))
            // A merge request or work item by its link or `group/project!123`, in its list or under "Opened" (WIN-06).
            Button("Open by Link…") {
                router.promptOpenByLink()
            }
            .keyboardShortcut(shortcut("openByLink"))
            .disabled(sheetIsUp || router.isOpeningByLink)
            Divider()
            // In Workspaces ⌘O opens the checkout, as Return does; its merge request or work item opens without a shortcut.
            if let checkout = selectedCheckout {
                Button(checkout.hasIDECommand ? "Open in IDE" : "Reveal in Finder") {
                    checkout.open()
                }
                .keyboardShortcut(shortcut("openSelected"))
                .disabled(sheetIsUp)
                Button("Open in Browser") {
                    if let url = selectedLink {
                        router.browse(url)
                    }
                }
                .disabled(sheetIsUp || selectedLink == nil)
            } else {
                Button("Open in Browser") {
                    if let url = selectedLink {
                        router.browse(url)
                    }
                }
                .keyboardShortcut(shortcut("openSelected"))
                .disabled(sheetIsUp || selectedLink == nil)
            }
            Button("Copy Link") {
                if let url = selectedLink {
                    MainWindowLinks.copy(url)
                }
            }
            .keyboardShortcut(shortcut("copyLink"))
            .disabled(sheetIsUp || selectedLink == nil)
            // While an item under "Opened" is selected, ⌘W closes it as a tab; with none, it stays Close Window's (WIN-06).
            Button("Close Opened Item") {
                if let id = router.opened {
                    router.close(opened: id, in: model.opened)
                }
            }
            .keyboardShortcut(selectedOpenedItem == nil ? nil : shortcut("closeOpened"))
            .disabled(sheetIsUp || selectedOpenedItem == nil)
            Divider()
            Button("Show in Finder") {
                ActivityFinder.show(model.activity)
            }
            .keyboardShortcut(shortcut("showInFinder"))
            Button("Clear Activity…") {
                activityCommands?.clear()
            }
            .keyboardShortcut(shortcut("clearActivity"))
            .disabled(activityCommands == nil)
        }
        CommandGroup(replacing: .textEditing) {
            // The system's Find submenu would add a second Find… ⌘F, so this one replaces the group.
            Menu("Find") {
                Button("Find…") {
                    router.focusSearch()
                }
                .keyboardShortcut(shortcut("find"))
                .disabled(focusedSection == nil || sheetIsUp)
            }
        }
        CommandGroup(after: .sidebar) {
            // Activity's inspector (LOG-04), after Show Sidebar as Apple's InspectorCommands put it, with their ⌃⌘I.
            Button(activityCommands?.isInspectorShown == true ? "Hide Inspector" : "Show Inspector") {
                activityCommands?.toggleInspector()
            }
            .keyboardShortcut(shortcut("toggleInspector"))
            .disabled(activityCommands == nil)
            Divider()
            ForEach(
                Array(
                    MainWindowSection.sidebarSections(
                        claudeIsOffered: model.ai.isOffered, shown: router.section, order: sectionOrder
                    ).enumerated()),
                id: \.element
            ) { index, section in
                Button(section.title) {
                    router.open(section)
                    router.focusList()
                }
                // ⌘1 and on, by the place in the sidebar; a tenth section has no key (KEYS-01).
                .keyboardShortcut(index < 9 ? shortcut(ShortcutCatalog.sectionID(index + 1)) : nil)
                .disabled(sheetIsUp)
            }
            Divider()
            Menu("Work Item Filters") {
                WorkItemFilterItems(filters: WorkItemFilterItems.binding(model.settings)) {
                    model.settings.reveal(.workItemFilters)
                    router.open(.settings(pane: .gitLab))
                }
            }
            Menu("Activity Filters") {
                ActivityFilterItems(activity: model.activity)
            }
            Divider()
            // The descriptions' reading size, app-wide (WIN-02). ⌘= is the unshifted way to ⌘+, as in Apple's apps.
            Button("Make Text Bigger") {
                readingSizeStep = MarkdownReadingSize.step(readingSizeStep, changedBy: 1)
            }
            .keyboardShortcut(shortcut("biggerText"))
            .disabled(!MarkdownReadingSize.canGrow(from: readingSizeStep))
            // While Bigger has its standard key, ⌘= works too, as ⌘+ does without Shift.
            if !shortcuts.isCustomized("biggerText") {
                Button("Make Text Bigger") {
                    readingSizeStep = MarkdownReadingSize.step(readingSizeStep, changedBy: 1)
                }
                .keyboardShortcut("=")
                .disabled(!MarkdownReadingSize.canGrow(from: readingSizeStep))
                .hidden()
            }
            Button("Make Text Smaller") {
                readingSizeStep = MarkdownReadingSize.step(readingSizeStep, changedBy: -1)
            }
            .keyboardShortcut(shortcut("smallerText"))
            .disabled(!MarkdownReadingSize.canShrink(from: readingSizeStep))
            // ⌘0 is the window item's too: while the main window is key it is Actual Size's, as that window is already forward.
            Button("Actual Size") {
                readingSizeStep = MarkdownReadingSize.step(readingSizeStep, changedBy: 0)
            }
            .keyboardShortcut(focusedSection == nil ? nil : shortcut("actualSize"))
            .disabled(MarkdownReadingSize.isDefault(readingSizeStep))
            Divider()
        }
        // Back and Forward, as in a browser (WIN-08); ⌘← and ⌘→ and the mouse's buttons are the window's own.
        CommandMenu("Go") {
            Button("Back") {
                router.goBack(model: model)
            }
            .keyboardShortcut(shortcut("back"))
            .disabled(focusedSection == nil || sheetIsUp || !router.history.canGoBack)
            Button("Forward") {
                router.goForward(model: model)
            }
            .keyboardShortcut(shortcut("forward"))
            .disabled(focusedSection == nil || sheetIsUp || !router.history.canGoForward)
        }
        CommandMenu("Builds") {
            // While the main window is key, ⌘R reloads its section only (the user, 2026-10-30), and the app-wide Check Now
            // takes ⇧⌘R; otherwise Check Now keeps ⌘R.
            Button(focusedSection.map { MainWindowReload.title(for: $0, opened: router.opened != nil) } ?? "Reload") {
                if let section = focusedSection {
                    MainWindowReload.run(section, selection: router.selection, opened: router.opened, model: model)
                }
            }
            .keyboardShortcut(focusedSection == nil ? nil : shortcut("reload"))
            .disabled(
                sheetIsUp
                    || focusedSection.map {
                        !MainWindowReload.isAvailable(in: $0, opened: router.opened != nil)
                    } ?? true)
            Button("Check Now") {
                model.checkNow()
            }
            .keyboardShortcut(focusedSection == nil ? KeyboardShortcut("r") : shortcut("checkNow"))
            Button("Watch a Build…") {
                router.open(.watch(MergeRequestWatching.request(model: model, router: router)))
            }
            .keyboardShortcut(shortcut("watchBuild"))
            .disabled(sheetIsUp)
            // The selected merge request's job, in one click, as the detail's button (WATCH-01).
            Button("Watch Builds of Merge Request") {
                if let mergeRequest = selectedMergeRequestToWatch {
                    MergeRequestWatching.watch(mergeRequest, model: model, router: router)
                }
            }
            .keyboardShortcut(shortcut("watchMergeRequest"))
            .disabled(sheetIsUp || selectedMergeRequestToWatch == nil)
            Divider()
            Button(PipelinesStore.showHiddenTitle(count: model.projects.hiddenCount) ?? "Show Hidden Builds") {
                model.projects.unhideAll()
            }
            .keyboardShortcut(shortcut("showHiddenBuilds"))
            .disabled(model.projects.hiddenCount == 0)
            // The list's link row can be out of reach with the keyboard only (PIPELINES-04).
            Button("All Builds in Jenkins") {
                if let url = model.pipelines.project.team.jenkinsJob {
                    router.browse(url)
                }
            }
            .keyboardShortcut(shortcut("allBuildsInJenkins"))
            .disabled(model.pipelines.project.team.jenkinsJob == nil)
            Divider()
            // ⌘⌫ goes to whichever of the two the selected row has: a watched build is stopped, any other hidden.
            Button("Hide Until the Next Build") {
                if let build = selectedBuild {
                    model.projects.hide(build)
                    router.selection.pipelines = nil
                }
            }
            .keyboardShortcut(selectedWatchedJob == nil ? shortcut("hideBuild") : nil)
            .disabled(sheetIsUp || selectedBuild == nil)
            Button("Stop Watching") {
                if let job = selectedWatchedJob {
                    model.projects.unwatch(jobKey: job)
                    router.selection.pipelines = nil
                }
            }
            .keyboardShortcut(selectedWatchedJob != nil ? shortcut("hideBuild") : nil)
            .disabled(sheetIsUp || selectedWatchedJob == nil)
        }
        CommandGroup(replacing: .singleWindowList) {
            // Replaced, so ⌘0 goes through the activation helper and the welcome flow isn't listed (`main-window.md`).
            MainWindowMenuItem(router: router, handOver: handOver, shortcut: shortcut("openMainWindow"))
        }
        // No help book, but "What's New…" shows the changelog anytime, as the Inbox's entry after an update does.
        CommandGroup(replacing: .help) {
            Button("What's New…") {
                router.showWhatsNew()
            }
            .disabled(sheetIsUp)
        }
    }

    /// the user's shortcuts, which Settings → Shortcuts changes (KEYS-01)
    private var shortcuts: ShortcutMap {
        model.settings.preferences.shortcuts
    }

    /// the shortcut of a command as its menu item has it
    private func shortcut(_ id: String) -> KeyboardShortcut? {
        shortcuts.keyboardShortcut(id)
    }

    /// Opens GitLab's new issue page for an entry point in the browser.
    private func openNewWorkItem(_ source: NewWorkItemSource) {
        NewWorkItemLauncher.action(model: model) { [router] in router.browse($0) }?(source)
    }

    /// whether the Watch a Build… or the Rebuild with Changes… sheet is up, which are modal
    private var sheetIsUp: Bool {
        router.watchRequest != nil || router.rebuildRequest != nil
    }

    /// the item selected under "Opened" while the main window is key
    private var selectedOpenedItem: OpenedItem? {
        focusedSection == nil ? nil : router.opened.flatMap { model.opened.item($0) }
    }

    /// the selected row's link while the main window is key
    private var selectedLink: URL? {
        focusedSection == nil ? nil : MainWindowLinks.selected(model, router: router)
    }

    /// the selected checkout in Workspaces while the main window is key, with what ⌘O does to it
    private var selectedCheckout: (hasIDECommand: Bool, open: @MainActor () -> Void)? {
        guard focusedSection == .workspaces else {
            return nil
        }
        let list = WorkspacesListModel(WorkspacesData(model, now: Date()))
        guard let row = list.row(router.selection.workspaces) else {
            return nil
        }
        let store = model.workspaces
        let checkout = row.checkout
        let hasIDE = list.hasIDECommand
        return (hasIDE, { Task { hasIDE ? await store.openInIDE(checkout) : await store.revealInFinder(checkout) } })
    }

    /// the selected merge request while the main window is key, when "Watch Builds" is on offer for it
    private var selectedMergeRequestToWatch: MergeRequest? {
        guard focusedSection == .mergeRequests,
            let detail = MergeRequestDetailModel(
                MergeRequestsData(model, now: Date()), selection: router.selection.mergeRequests),
            case .watch = detail.watch
        else {
            return nil
        }
        return detail.mergeRequest
    }

    /// the selected build in Pipelines while the main window is key; a waiting job has none
    private var selectedBuild: Build? {
        guard focusedSection == .pipelines, let job = router.selection.pipelines else {
            return nil
        }
        return (model.projects.myBuilds + model.projects.watchedBuilds).first { $0.jobKey == job }
    }

    /// the selected watched job in Pipelines while the main window is key, with a build or waiting
    private var selectedWatchedJob: String? {
        guard focusedSection == .pipelines, let job = router.selection.pipelines else {
            return nil
        }
        let shown = Set(model.projects.watchedBuilds.map(\.jobKey))
            .union(model.pipelines.watchedJobs.filter(\.isWaiting).map(\.watched.job))
        return shown.contains(job) ? job : nil
    }
}

/// Window › MegaMonitor (⌘0): opens the main window, or brings it forward. Its view reads SwiftUI's window actions
/// from the environment, as views do, and hands them over to the app whenever it runs, so the app can open windows
/// before any other view appeared: with "Show in menu bar" off no view appears at launch (APP-03).
private struct MainWindowMenuItem: View {
    let router: WindowRouter
    let handOver: (@MainActor (OpenWindowAction, OpenSettingsAction) -> Bool)?
    /// the shortcut of Settings → Shortcuts, which counts while another window is in front
    let shortcut: KeyboardShortcut?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @FocusedValue(\.mainWindowSection) private var focusedSection

    var body: some View {
        Button(AppIdentity.displayName) {
            if handOver?(openWindow, openSettings) == true {
                return
            }
            router.open(.main)
        }
        .keyboardShortcut(focusedSection == nil ? shortcut : nil)
    }
}

/// View › Activity Filters: the Level and Source choices of the Activity section's filter bar, with checkmarks on the
/// store's current values, which it remembers (LOG-04).
private struct ActivityFilterItems: View {
    let activity: ActivityStore

    var body: some View {
        Picker("Level", selection: Binding(get: { activity.levelFilter }, set: { activity.levelFilter = $0 })) {
            ForEach(ActivityLevelFilter.allCases, id: \.self) { filter in
                Text(verbatim: filter.title).tag(filter)
            }
        }
        .pickerStyle(.inline)
        Picker("Source", selection: Binding(get: { activity.sourceFilter }, set: { activity.sourceFilter = $0 })) {
            Text("All Sources").tag(ActivityEntry.Source?.none)
            ForEach(ActivityEntry.Source.allCases, id: \.self) { source in
                Text(verbatim: source.displayName).tag(ActivityEntry.Source?.some(source))
            }
        }
        .pickerStyle(.inline)
    }
}
