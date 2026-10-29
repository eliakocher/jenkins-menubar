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
/// in the app menu, New Work Item… (⌘N), Open in Browser (⌘O), Find… (⌘F), Activity's inspector (⌃⌘I), the sections (⌘1 to ⌘4), the
/// Builds menu (⌘R, ⌘L, the hidden builds, the selected build's commands), the window (⌘0) and no help book.
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

    /// - Parameters:
    ///   - model: the app's model
    ///   - router: the app's one router
    ///   - handOver: takes SwiftUI's window actions from the Window menu's "menubar-monitor" command whenever it runs,
    ///     and returns whether a window waited for them, which the command then doesn't follow with the main window.
    ///     The app performs that command itself while no view has handed the actions over yet (APP-03).
    public init(
        model: AppModel, router: WindowRouter,
        handOver: (@MainActor (OpenWindowAction, OpenSettingsAction) -> Bool)? = nil
    ) {
        self.model = model
        self.router = router
        self.handOver = handOver
    }

    /// Shows the standard About panel with the credits as the easter eggs setting has them.
    private func showAbout() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(
            string: EggRules.credits(eggs: model.pipelines.preferences.easterEggs),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ])
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    public var body: some Commands {
        SidebarCommands()
        // The About panel with its credits: the butler's CC BY-SA attribution always, and the roll with the easter eggs on
        // (EGG-21).
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppIdentity.name)") {
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
            .keyboardShortcut("n")
            .disabled(sheetIsUp || !NewWorkItemLauncher.canOpen(model))
            Menu("New Work Item As") {
                ForEach(WorkItemKind.allCases, id: \.self) { kind in
                    Button(kind.title) { openNewWorkItem(.blank(kind)) }
                }
            }
            .disabled(sheetIsUp || !NewWorkItemLauncher.canOpen(model))
            Divider()
            // In Workspaces ⌘O opens the checkout, as Return does; its merge request or work item opens without a shortcut.
            if let checkout = selectedCheckout {
                Button(checkout.hasIDECommand ? "Open in IDE" : "Reveal in Finder") {
                    checkout.open()
                }
                .keyboardShortcut("o")
                .disabled(sheetIsUp)
                Button("Open in Browser") {
                    if let url = selectedLink {
                        NSWorkspace.shared.open(url)
                    }
                }
                .disabled(sheetIsUp || selectedLink == nil)
            } else {
                Button("Open in Browser") {
                    if let url = selectedLink {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("o")
                .disabled(sheetIsUp || selectedLink == nil)
            }
            Button("Copy Link") {
                if let url = selectedLink {
                    MainWindowLinks.copy(url)
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(sheetIsUp || selectedLink == nil)
            Divider()
            Button("Show in Finder") {
                ActivityFinder.show(model.activity)
            }
            Button("Clear Activity…") {
                activityCommands?.clear()
            }
            .disabled(activityCommands == nil)
        }
        CommandGroup(replacing: .textEditing) {
            // The system's Find submenu would add a second Find… ⌘F, so this one replaces the group.
            Menu("Find") {
                Button("Find…") {
                    router.focusSearch()
                }
                .keyboardShortcut("f")
                .disabled(focusedSection == nil || sheetIsUp)
            }
        }
        CommandGroup(after: .sidebar) {
            // Activity's inspector (LOG-04), after Show Sidebar as Apple's InspectorCommands put it, with their ⌃⌘I.
            Button(activityCommands?.isInspectorShown == true ? "Hide Inspector" : "Show Inspector") {
                activityCommands?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.control, .command])
            .disabled(activityCommands == nil)
            Divider()
            ForEach(Array(MainWindowSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) {
                    router.open(section)
                    router.focusList()
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                .disabled(sheetIsUp)
            }
            Divider()
            Menu("Work Item Filters") {
                WorkItemFilterItems(filters: WorkItemFilterItems.binding(model.settings)) {
                    router.open(.settings(pane: .gitLab))
                }
            }
            Menu("Activity Filters") {
                ActivityFilterItems(activity: model.activity)
            }
            Divider()
        }
        CommandMenu("Builds") {
            Button("Check Now") {
                model.checkNow()
            }
            .keyboardShortcut("r")
            Button("Watch a Build…") {
                router.open(.watch(MergeRequestWatching.request(model: model, router: router)))
            }
            .keyboardShortcut("l")
            .disabled(sheetIsUp)
            // The selected merge request's job, in one click, as the detail's button (WATCH-01).
            Button("Watch Builds of Merge Request") {
                if let mergeRequest = selectedMergeRequestToWatch {
                    MergeRequestWatching.watch(mergeRequest, model: model, router: router)
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(sheetIsUp || selectedMergeRequestToWatch == nil)
            Divider()
            Button(PipelinesStore.showHiddenTitle(count: model.projects.hiddenCount) ?? "Show Hidden Builds") {
                model.projects.unhideAll()
            }
            .disabled(model.projects.hiddenCount == 0)
            // The list's link row can be out of reach with the keyboard only (PIPELINES-04).
            Button("All Builds in Jenkins") {
                if let url = model.pipelines.project.team.jenkinsJob {
                    NSWorkspace.shared.open(url)
                }
            }
            .disabled(model.pipelines.project.team.jenkinsJob == nil)
            Divider()
            // ⌘⌫ goes to whichever of the two the selected row has: a watched build is stopped, any other hidden.
            Button("Hide Until the Next Build") {
                if let build = selectedBuild {
                    model.projects.hide(build)
                    router.selection.pipelines = nil
                }
            }
            .keyboardShortcut(selectedWatchedJob == nil ? KeyboardShortcut(.delete, modifiers: .command) : nil)
            .disabled(sheetIsUp || selectedBuild == nil)
            Button("Stop Watching") {
                if let job = selectedWatchedJob {
                    model.projects.unwatch(jobKey: job)
                    router.selection.pipelines = nil
                }
            }
            .keyboardShortcut(selectedWatchedJob != nil ? KeyboardShortcut(.delete, modifiers: .command) : nil)
            .disabled(sheetIsUp || selectedWatchedJob == nil)
        }
        CommandGroup(replacing: .singleWindowList) {
            // Replaced, so ⌘0 goes through the activation helper and the welcome flow isn't listed (`main-window.md`).
            MainWindowMenuItem(router: router, handOver: handOver)
        }
        CommandGroup(replacing: .help) {}
    }

    /// Opens GitLab's new issue page for an entry point in the browser.
    private func openNewWorkItem(_ source: NewWorkItemSource) {
        NewWorkItemLauncher.action(model: model) { NSWorkspace.shared.open($0) }?(source)
    }

    /// whether the Watch a Build… sheet is up, which is modal
    private var sheetIsUp: Bool {
        router.watchRequest != nil
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

/// Window › menubar-monitor (⌘0): opens the main window, or brings it forward. Its view reads SwiftUI's window actions
/// from the environment, as views do, and hands them over to the app whenever it runs, so the app can open windows
/// before any other view appeared: with "Show in menu bar" off no view appears at launch (APP-03).
private struct MainWindowMenuItem: View {
    let router: WindowRouter
    let handOver: (@MainActor (OpenWindowAction, OpenSettingsAction) -> Bool)?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(AppIdentity.name) {
            if handOver?(openWindow, openSettings) == true {
                return
            }
            router.open(.main)
        }
        .keyboardShortcut("0")
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
