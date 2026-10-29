import AppKit
import MenubarCore
import SwiftUI

/// The menubar pane (APP-06, `docs/design/panel.md`): the content of the status item's glass panel, an overview that
/// feels like a native macOS 26 menu. A problem row while there is one, one row per area (Pipelines, Merge Requests,
/// Work Items) whose flyout lists the area beside the pane on hover, and the footer's commands.
///
/// It reads the stores and the router from the environment (``SwiftUICore/View/appEnvironment(_:router:)``),
/// refreshed at least every 10 s for the running builds' times; ``MenuPaneController`` holds the highlight, the hover
/// timing and the flyout's panel.
/// - On open: it tells the scheduler the GitLab surfaces show (OD-02), so the summaries and the flyouts load; moves the
///   hiding rules' time on (HIDE-02) and checks for an update (APP-05). On close: they no longer show, and the flyout
///   closes.
/// - Every action that opens a window, Settings or a web page closes the pane, which opening doesn't do by itself
///   (`docs/decisions.md`, Task 0.10).
public struct MenuPaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ViewState private var controller = MenuPaneController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    public init() {}

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let pane = paneModel(at: context.date)
            MenuPaneContent(model: pane, navigation: controller.navigation, events: events)
                .onChange(of: Self.rows(of: pane), initial: true) { _, rows in
                    controller.navigation.paneRows = rows
                }
        }
        .focusable()
        .focusEffectDisabled()
        .background {
            // ⌘L from the pane too, though Watch a Build… moved into the Pipelines flyout.
            Button("Watch a Build…") { panelActions.watchBuild() }
                .keyboardShortcut("l")
                .hidden()
        }
        .focused($isFocused)
        .onKeyPress(keys: Self.handledKeys) { press in
            handle(press.key)
        }
        .onAppear {
            controller.flyout = { [model] area in MenuFlyout(PanelView.data(model, now: .now), area: area) }
            controller.makeFlyoutRoot = makeFlyoutRoot
            controller.paneAppeared()
            isFocused = true
            // The summaries and the flyouts show the GitLab data, so it loads while the pane is open (OD-02).
            router.report(PanelView.surfaces, shownBy: PanelView.host, to: model.scheduler)
            model.projects.refreshTime()
            let updates = model.updates
            Task { await updates.check() }
        }
        .onDisappear {
            controller.paneDisappeared()
            router.report([], shownBy: PanelView.host, to: model.scheduler)
        }
    }

    /// Returns what the pane shows at a time, with the easter eggs: Option's Quit title and the mashed Check Now's line
    /// (EGG-09, EGG-10).
    private func paneModel(at date: Date) -> MenuPaneModel {
        var pane = MenuPaneModel(PanelView.data(model, now: date))
        pane.easterEggs = model.pipelines.preferences.easterEggs
        pane.footer.eggLine = pane.easterEggs ? model.eggs.mashLine : nil
        return pane
    }

    /// Returns the rows the keys move over.
    static func rows(of pane: MenuPaneModel) -> [MenuNavigation.PaneRow] {
        MenuNavigation.paneRows(problemIsLinked: pane.problem?.pane != nil, areas: pane.areas.map(\.section))
    }

    private var events: MenuPaneEvents {
        let controller = controller
        return MenuPaneEvents(
            hover: { controller.hover($0) },
            leave: { controller.leavePane() },
            activate: { activate($0) },
            anchor: { controller.register($0, view: $1) })
    }

    /// Does what a pane row does: an area opens its flyout, and a second click opens the main window there.
    private func activate(_ row: MenuNavigation.PaneRow) {
        let actions = panelActions
        switch row {
        case .problem:
            if let pane = MenuPaneModel(PanelView.data(model, now: .now)).problem?.pane {
                actions.openSettings(pane)
            }
        case .area(let section):
            if controller.navigation.openArea == section {
                actions.openSection(section)
            } else {
                controller.open(section)
            }
        case .checkNow:
            actions.checkNow()
        case .openWindow:
            actions.openWindow()
        case .settings:
            actions.openSettings(.general)
        case .quit:
            actions.quit()
        }
    }

    private func handle(_ key: KeyEquivalent) -> SwiftUI.KeyPress.Result {
        let eggs = model.pipelines.preferences.easterEggs
        if let konami = Self.konamiKey(key) {
            model.eggs.key(konami, enabled: eggs, reduceMotion: reduceMotion)
        }
        let mapped: MenuNavigation.Key
        switch key {
        case .upArrow: mapped = .up
        case .downArrow: mapped = .down
        case .leftArrow: mapped = .left
        case .rightArrow: mapped = .right
        case .return: mapped = .enter
        case .escape: mapped = .escape
        case "a", "b": return eggs ? .handled : .ignored
        default: return .ignored
        }
        switch controller.handle(mapped) {
        case .none:
            return .handled
        case .ignored:
            return .ignored
        case .activate(let row):
            activate(row)
        case .activateFlyout(let index):
            if let area = controller.navigation.openArea, let flyout = controller.flyout(area),
               flyout.items.indices.contains(index) {
                perform(flyout.items[index], in: flyout)
            }
        case .closePane:
            dismiss()
        }
        return .handled
    }

    /// Does what a flyout row does: an entry opens in Jenkins or GitLab, a command does its thing.
    private func perform(_ item: MenuFlyout.Item, in flyout: MenuFlyout) {
        let actions = panelActions
        switch item {
        case .entry(let id):
            if let url = flyout.entry(id)?.url {
                actions.open(url)
            }
        case .command(.showInWindow):
            actions.openSection(flyout.area)
        case .command(.showHidden):
            actions.showHidden()
        case .command(.link(_, let url)):
            actions.open(url)
        case .command(.settings(let pane)):
            actions.openSettings(pane)
        case .command(.watchBuild):
            actions.watchBuild()
        }
    }

    /// Shows an entry in the main window: its section with the entry selected (WIN-05).
    private func showInWindow(_ selection: MenuSelection) {
        switch selection {
        case .build(let job): router.selection.pipelines = job
        case .mergeRequest(let id): router.selection.mergeRequests = id
        case .workItem(let id): router.selection.workItems = id
        }
        router.open(selection.section)
        dismiss()
    }

    /// The flyout panel's root: the open area's flyout, live from the stores, in the app's environment.
    private func makeFlyoutRoot() -> AnyView {
        let controller = controller
        let actions = MenuFlyoutActions(
            hover: { controller.hoverFlyout($0) },
            inside: { controller.pointerInFlyout($0) },
            activate: { item in
                if let area = controller.navigation.openArea, let flyout = controller.flyout(area) {
                    perform(item, in: flyout)
                }
            },
            panel: panelActions,
            showInWindow: { showInWindow($0) })
        let model = model
        let host = MenuFlyoutHost(controller: controller, actions: actions) { PanelView.data(model, now: $0) }
        return AnyView(host.appEnvironment(model, router: router))
    }

    /// The actions the pane shares with the old panel's rows, so a build's context menu is the same everywhere.
    private var panelActions: PanelActions {
        let model = model
        let router = router
        let dismiss = dismiss
        let openURL = openURL
        return PanelActions(
            open: { url in
                openURL(url)
                dismiss()
            },
            openSettings: { pane in
                router.open(.settings(pane: pane))
                dismiss()
            },
            openWindow: {
                router.open(.main)
                dismiss()
            },
            watchBuild: {
                router.open(.watch(WatchRequest()))
                dismiss()
            },
            checkNow: { model.checkNow() },
            showHidden: { model.projects.unhideAll() },
            rebuild: {},
            quit: { NSApp.terminate(nil) },
            hide: { model.projects.hide($0) },
            stopWatching: { model.pipelines.unwatch($0) },
            copy: { url in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            },
            close: { dismiss() },
            // The pane stays open, so the row's "Rebuilding…" shows (PIPE-09).
            rebuildBuild: { model.projects.rebuild($0) },
            cancelRebuild: { job in
                let projects = model.projects
                Task { await projects.cancelRebuild(jobKey: job) }
            },
            openSection: { section in
                router.open(section)
                dismiss()
            },
            newWorkItem: NewWorkItemLauncher.action(model: model) { url in
                openURL(url)
                dismiss()
            })
    }
}

/// The flyout panel's content: the open area's flyout from the stores, refreshed at least every 10 s, in a scroll
/// view that scrolls only when the screen is too short; it reports its height so the panel fits it.
struct MenuFlyoutHost: View {
    let controller: MenuPaneController
    let actions: MenuFlyoutActions
    /// Returns what the stores hold at a time; the gallery returns its fixtures.
    let data: @MainActor (Date) -> PanelData

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            if let area = controller.navigation.openArea {
                let flyout = MenuFlyout(data(context.date), area: area)
                ScrollViewReader { proxy in
                    ScrollView {
                        MenuFlyoutContent(flyout: flyout, highlight: controller.navigation.flyoutHighlight, actions: actions)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                controller.contentHeightChanged(height)
                            }
                    }
                    .scrollEdgeEffectHidden()
                    .onChange(of: controller.navigation.flyoutHighlight) { _, index in
                        if let index, flyout.items.indices.contains(index) {
                            proxy.scrollTo(flyout.items[index])
                        }
                    }
                }
            }
        }
    }
}
