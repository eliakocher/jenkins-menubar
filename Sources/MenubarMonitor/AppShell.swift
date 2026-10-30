import AppKit
import MenubarCore
import MenubarUI
import Observation

/// What the app holds beside the views: the model, the windows, and the steps at launch.
///
/// At launch it imports from jenkins-menubar (`LegacyImport.runIfNeeded()`), reloads what the import changed, and
/// only then starts the checks, so the first check already has the imported tokens and team values. The model exists
/// before, so the panel draws the cached builds at once (OD-01).
///
/// Every window opens through the one ``router``: the views call it, and so do the `menubar-monitor://` links and
/// starting the app again. Its closure opens the windows through the ``presenter``.
@MainActor
@Observable
final class AppShell {
    let presenter: WindowPresenter
    /// the router every scene gets in its environment
    let router: WindowRouter
    let model: AppModel
    /// the opt-in link router: web links to Jenkins and GitLab items open in the window (APP-09)
    let linkRouting: LinkRouting

    @ObservationIgnored private let legacySources: LegacySources
    @ObservationIgnored private var launching: Task<Void, Never>?
    @ObservationIgnored private var wakeWatcher: Task<Void, Never>?
    /// runs when the app quits, after the checks stopped
    @ObservationIgnored var onStop: (() -> Void)?

    /// Where the import looks for jenkins-menubar's files and tokens.
    struct LegacySources {
        var locations: LegacyImport.Locations
        var oldTokens: LegacyTokenFinder

        /// the user's own: the checkout the app was built from, SwiftBar's plugin folder, `~/bin/jenkins-watch`, the
        /// old keychain service, the environment and `~/.zshrc`
        static func standard() -> LegacySources {
            let checkout = BuildStamp(infoDictionary: Bundle.main.infoDictionary)?.sourceRoot
            return LegacySources(locations: .standard(storedCheckout: checkout), oldTokens: .standard())
        }

        /// places inside a folder that don't exist, and no old keychain, environment or `~/.zshrc`: the import runs,
        /// finds nothing and records that
        static func none(in folder: URL) -> LegacySources {
            let old = folder.appending(path: "jenkins-menubar", directoryHint: .isDirectory)
            return LegacySources(
                locations: LegacyImport.Locations(
                    storedCheckout: nil, swiftBarPluginFolder: nil,
                    watchLink: old.appending(path: "bin/jenkins-watch", directoryHint: .notDirectory),
                    caches: old.appending(path: "Caches", directoryHint: .isDirectory)),
                oldTokens: LegacyTokenFinder(oldKeychain: MemoryKeychain(), environment: [:], zshrc: nil))
        }
    }

    /// - Parameters:
    ///   - model: the model, not started yet
    ///   - legacySources: where the import looks
    ///   - defaultBrowser: macOS's default browser; the throwaway and smoke runs pass one that changes nothing
    init(model: AppModel, legacySources: LegacySources, defaultBrowser: any DefaultBrowserSystem = NativeDefaultBrowser()) {
        let presenter = WindowPresenter()
        self.presenter = presenter
        // The main window's section and selections are kept with the preferences (WIN-05).
        self.router = WindowRouter(
            defaults: model.dependencies.preferences,
            open: AppShell.opener(presenter: presenter, settings: model.settings))
        self.model = model
        self.legacySources = legacySources
        let log = model.log
        // Captures the model, not its TeamStore: a release build can't link a closure that holds that struct.
        linkRouting = LinkRouting(
            system: defaultBrowser, defaults: model.dependencies.preferences, projects: { model.team.projects() },
            log: { message in Task { await log.log(.info, .app, message) } })
        // The panel's "Update Ready — Rebuild" rebuilds through the update store, then hands over here.
        router.onRebuilt = { app in AppShell.relaunch(app) }
        router.openInBrowser = { [weak self] url in self?.openInBrowser(url) }
        model.hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
    }

    /// The global hotkey (APP-08): opens the main window from anywhere and brings it forward. Pressed again while the
    /// window is in front, it hides the app, so one shortcut shows and dismisses it.
    func hotkeyPressed() {
        if presenter.isMainWindowFront {
            NSApp.hide(nil)
        } else {
            router.open(.main)
        }
    }

    /// Returns the router's closure, which opens a route with the activation helper of Task 0.11.
    ///
    /// - Parameters:
    ///   - presenter: opens the windows
    ///   - settings: selects the pane before Settings opens
    /// - Returns: the closure for `WindowRouter(open:)`
    private static func opener(
        presenter: WindowPresenter, settings: SettingsStore
    ) -> @MainActor (WindowRoute) -> Void {
        { route in
            switch route {
            case .main, .watch:
                // For a watch, the router holds the request already; the main window shows the sheet for it.
                presenter.showMainWindow()
            case .settings(let pane):
                if let pane {
                    settings.selectedPane = pane
                }
                presenter.showSettings()
            }
        }
    }

    /// Returns the app's shell, built from the real dependencies.
    static func standard(effects: NativeEffects) -> AppShell {
        let dependencies = Dependencies.standard(
            effects: effects, systemEvents: WorkspaceSystemEvents(), loginItem: MainAppLoginItem(),
            hotkeys: CarbonHotkeys())
        let model = AppModel(dependencies: dependencies)
        // The morning digest, when the user turns it on, comes as a banner (AI-04).
        model.ai.notify = { text in await effects.postDigest(text) }
        return AppShell(model: model, legacySources: .standard())
    }

    /// whether the status item is in the menu bar (APP-01). Removing it by hand turns it off; the checks and alerts go
    /// on either way. Settings saves and logs the change (SET-01).
    var showInMenuBar: Bool {
        get { model.settings.preferences.showInMenuBar }
        set {
            // MenuBarExtra(isInserted:) writes the value it has at every update of the scene; a write that notifies
            // the observers would loop (Task 4.2). The settings store ignores it too, but that's its detail.
            guard newValue != showInMenuBar else {
                return
            }
            model.settings.preferences.showInMenuBar = newValue
        }
    }

    /// Imports from jenkins-menubar once, then starts the checks, opens the welcome flow when it is needed, and looks
    /// for an update now and at each wake (APP-05). Calling it again changes nothing.
    func launch() {
        guard launching == nil else {
            return
        }
        launching = Task {
            await importIfNeeded()
            model.start()
            // Whether claude is installed, which shows or hides the Claude features (AI-01): one login shell, once.
            Task { await model.ai.detect() }
            showWelcomeIfNeeded()
            await model.updates.check()
        }
        let events = model.dependencies.systemEvents.events()
        let updates = model.updates
        wakeWatcher = Task {
            for await event in events where event == .didWake {
                await updates.check()
            }
        }
    }

    /// Runs the import unless it ran before, then hands its report to the model, which reads everything again and
    /// loads the tokens (IMP-01, ACC-02).
    ///
    /// - Returns: what the import did; nil when it had run before
    @discardableResult
    func importIfNeeded() async -> LegacyImportReport? {
        let legacyImport = makeLegacyImport()
        let report = await legacyImport.runIfNeeded()
        await model.importFinished(report ?? legacyImport.recordedReport())
        return report
    }

    /// Imports from the old tool's folder that people chose in the welcome flow, whether an import ran before or not,
    /// then hands the new report to the model, so the flow's lines follow it (IMP-01).
    ///
    /// - Parameter folder: the chosen folder
    func importChosenFolder(_ folder: URL) async {
        let report = await makeLegacyImport().run(chosenFolder: folder)
        await model.importFinished(report)
    }

    private func makeLegacyImport() -> LegacyImport {
        let dependencies = model.dependencies
        return LegacyImport(
            locations: legacySources.locations,
            oldTokens: legacySources.oldTokens,
            keychain: dependencies.keychain,
            preferences: model.preferencesStore,
            teamStore: model.team,
            userState: model.userStates,
            applicationSupport: dependencies.fileLocations.applicationSupport,
            log: model.log,
            now: dependencies.now)
    }

    /// Opens the welcome flow at launch when it was never finished or closed, or while a required team value is
    /// missing (TEAM-03, IMP-03). With a Dock icon while it is open (APP-01).
    private func showWelcomeIfNeeded() {
        if model.settings.needsWelcomeFlow {
            presenter.showWelcome()
        }
    }

    /// Looks for an update when the panel or the main window opens (APP-05).
    func surfaceAppeared() {
        let updates = model.updates
        Task {
            await updates.check()
        }
    }

    /// Stops the checks, as the app quits.
    func stop() {
        launching?.cancel()
        wakeWatcher?.cancel()
        model.stop()
        model.removeHotkey()
        onStop?()
    }

    /// Rebuilds the app from its checkout, opens the new one and quits (APP-05). A failure leaves the app running, with
    /// the error row and the log entry the update store writes.
    func rebuildAndRelaunch() async {
        guard let app = await model.updates.rebuild() else {
            return
        }
        Self.relaunch(app)
    }

    /// Opens the rebuilt app once this one is gone, and quits (APP-05).
    ///
    /// - Parameter app: the installed app
    private static func relaunch(_ app: URL) {
        Relaunch.open(app)
        NSApp.terminate(nil)
    }

    /// Starts a build's rebuild, for the alert window's and the banner's Rebuild (PIPE-09). A banner click that starts
    /// the app waits for the launch, whose import may bring the token and the team values.
    ///
    /// - Parameter build: the build to start again
    func rebuild(_ build: BuildID) {
        Task {
            await launching?.value
            model.projects.rebuild(build)
        }
    }

    /// Hides a build until its job's next build (HIDE-01), for the alert window's and the banner's Hide. A banner click
    /// that starts the app waits for the launch, which loads the hidden builds.
    ///
    /// - Parameter build: the build to hide
    func hide(_ build: BuildID) {
        Task {
            await launching?.value
            model.projects.hide(build)
        }
    }

    /// Handles a web link that macOS gave this app as the default browser (APP-09): a Jenkins build, a GitLab merge request
    /// or work item opens in the window, in its list or under "Opened" (WIN-06); every other link, ⌥ held, or any link
    /// while the router is off goes on to the browser the user had. A link is never dropped.
    ///
    /// - Parameter url: the link
    func openLink(_ url: URL) {
        let route = linkRouting.route(url, optionHeld: NSEvent.modifierFlags.contains(.option))
        if show(route, link: url) {
            return
        }
        Task {
            if !(await linkRouting.forward(url)) {
                AppLog.error("no browser to pass a link to \(url.host(percentEncoded: false) ?? "no host") on")
            }
        }
    }

    /// Opens a link from the alert window or a banner: a build or merge request shows in the app, the console output and
    /// anything the app can't show opens in the browser (the user, 2026-10-30). Never through macOS, which would hand a
    /// link back to this app while it is the default browser.
    ///
    /// - Parameters:
    ///   - url: the link
    ///   - inApp: whether the app should show it, if it can
    func open(_ url: URL, inApp: Bool) {
        if inApp, router.openItemLink(url, model: model) {
            return
        }
        openInBrowser(url)
    }

    /// Shows a link's place in the main window: a build in Pipelines or under "Opened", a merge request or work item in
    /// its list or under "Opened".
    ///
    /// - Parameters:
    ///   - route: what ``LinkRouter`` made of the link
    ///   - link: the link, whose host picks the GitLab instance of an item that opens under "Opened"
    /// - Returns: whether it is shown; `false` leaves the link to the browser
    private func show(_ route: LinkRoute, link: URL) -> Bool {
        // The router off sends every link on (`LinkRouting.route`), so a link of the app's own never loops.
        guard route != .browser,
            let destination = model.destination(for: route, link: link, optionHeld: NSEvent.modifierFlags.contains(.option))
        else {
            return false
        }
        router.show(destination)
        return true
    }

    /// Opens a page in the real browser, never in this app, also while it is the Mac's default browser: "Open in GitLab"
    /// of an item under "Opened" must not come back here (WIN-06).
    ///
    /// - Parameter url: the page
    func openInBrowser(_ url: URL) {
        guard linkRouting.isOn else {
            NSWorkspace.shared.open(url)
            return
        }
        Task {
            if !(await linkRouting.forward(url)) {
                AppLog.error("no browser to pass a link to \(url.host(percentEncoded: false) ?? "no host") on")
            }
        }
    }

    /// Follows a `menubar-monitor://` link (APP-03), through the ``router``.
    func open(_ route: AppRoute) {
        switch route {
        case .settings(let pane):
            router.open(.settings(pane: pane))
        case .open(let section):
            router.open(section)
        case .mainWindow:
            // The window opens at the section it showed last.
            router.open(.main)
        case .watch(let target):
            Task {
                // The import may bring the token and the team values the confirmation needs.
                await launching?.value
                // A success shows nothing more: the build appears under Watching.
                if case .failure(let refusal) = await model.pipelines.watch(target) {
                    router.open(.watch(WatchRequest(text: target, refusal: refusal)))
                }
            }
        }
    }
}

#if DEBUG
extension AppShell {
    /// the option that starts the throwaway mode
    static let throwawayOption = "--throwaway"
    /// the preferences' suite of the throwaway mode, emptied when it starts and when it quits
    static let throwawaySuite = "\(AppIdentity.bundleID).throwaway"

    /// Returns a shell that runs the whole app on screen without the user's data, for manual checks and the design
    /// reviews of the real panel and windows (`MegaMonitor --throwaway`). Debug builds only.
    ///
    /// The files go into `MENUBAR_MONITOR_DATA_DIR`, or a new temporary folder; the preferences into a suite of their
    /// own; the tokens stay in memory, and there are none at first, so nothing reaches Jenkins or GitLab. The import
    /// finds nothing, no login item is registered and no rebuild is offered. The team values are made up, so the alert
    /// previews work.
    static func throwaway(effects: NativeEffects) -> AppShell {
        var environment = ProcessInfo.processInfo.environment
        if environment[FileLocations.dataDirectoryVariable]?.isEmpty ?? true {
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "menubar-monitor-throwaway-\(UUID().uuidString)", directoryHint: .isDirectory)
            environment[FileLocations.dataDirectoryVariable] = folder.path(percentEncoded: false)
        }
        // A suite name is never nil unless it is the app's own domain.
        let defaults = UserDefaults(suiteName: throwawaySuite)!
        defaults.removePersistentDomain(forName: throwawaySuite)
        var dependencies = Dependencies.standard(
            effects: effects, systemEvents: WorkspaceSystemEvents(), loginItem: InertLoginItem(), hotkeys: InertHotkeys(),
            defaults: defaults, environment: environment)
        dependencies.keychain = MemoryKeychain()
        dependencies.buildStamp = nil
        let locations = dependencies.fileLocations
        try? TeamStore(folder: locations.applicationSupport) { AppLog.warning($0) }.save(Project(id: .main, team: TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: "https://gitlab.example.com",
            gitLabProject: "group/project")))
        let root = URL(filePath: environment[FileLocations.dataDirectoryVariable]!, directoryHint: .isDirectory)
        let shell = AppShell(
            model: AppModel(dependencies: dependencies), legacySources: .none(in: root), defaultBrowser: InertDefaultBrowser())
        shell.onStop = {
            UserDefaults.standard.removePersistentDomain(forName: throwawaySuite)
        }
        print("throwaway: data in \(root.path(percentEncoded: false))")
        return shell
    }
}
#endif
