import CoreGraphics
import Foundation
import Observation

/// Runs Hot Corners (HOT-01…): watches the pointer while the settings need it, fires the action of the corner and the
/// modifier held, and tells Settings what it shows besides the settings themselves.
///
/// - The pointer is watched only while the model runs (``start()``) and the settings need it
///   (``HotCornerSettings/needsWatching``); the settings come in through ``apply(_:)``, at once on every change.
/// - A visit starts when the pointer enters a real corner (``HotCornerGeometry``). Once the corner's delay has passed,
///   the modifier held right then picks the action: none the plain one, one key its own, two keys or more nothing. An
///   empty slot does nothing; it doesn't fall back to the plain action.
/// - An action fires once per visit: the pointer has to leave the corner before it fires again. Nothing fires while a
///   mouse button is down, and a press ends the visit.
/// - A hold (``SystemCornerAction/isHold``) starts when the delay ends, and ends when the pointer leaves, a button is
///   pressed or the feature is switched off.
/// - The system actions go to the ``HotCornerSystem``; MegaMonitor's own to ``onAppAction``. Each fire is one line of
///   the Activity log.
@Observable @MainActor
public final class HotCornersController {
    /// whether the old Hot Corners app runs, so both would fire; Settings warns with a Quit button
    public private(set) var isLegacyAppRunning = false
    /// the user's shortcuts for the Run Shortcut menu, once loaded
    public private(set) var shortcutNames: [String] = []
    /// Called on the main actor for MegaMonitor's own actions (sections, the main window, Search…, Refresh Now, Mute
    /// Alerts); the app shell sets it.
    @ObservationIgnored public var onAppAction: (@MainActor (HotCornerAction) -> Void)?
    /// the settings followed now
    public private(set) var settings: HotCornerSettings
    /// whether the pointer is watched now
    public private(set) var isWatching = false
    /// the corner the pointer is in now, while watched; nil outside the corners
    public private(set) var currentCorner: HotCorner?

    @ObservationIgnored private let system: any HotCornerSystem
    @ObservationIgnored private let pointer: any PointerSource
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let log: ActivityLog?
    /// whether the model runs (``start()``)
    @ObservationIgnored private var isRunning = false
    /// where the pointer was at the last move, for the display of a glow
    @ObservationIgnored private var lastLocation: CGPoint?
    /// whether the action of the current visit fired, or was passed over
    @ObservationIgnored private var visitDone = false
    /// whether a hold runs
    @ObservationIgnored private var isHolding = false
    /// the wait for the corner's delay
    @ObservationIgnored private var delayTask: Task<Void, Never>?
    /// the log lines, in order
    @ObservationIgnored private var logTask: Task<Void, Never>?

    /// Creates the controller; nothing is watched before ``start()``.
    ///
    /// - Parameters:
    ///   - system: performs the macOS actions
    ///   - pointer: sends the pointer's moves
    ///   - clock: the clock of the delays
    ///   - log: the Activity log; nil logs nothing
    ///   - settings: the settings at the start
    public init(
        system: any HotCornerSystem, pointer: any PointerSource, clock: any Clock<Duration>, log: ActivityLog?,
        settings: HotCornerSettings = HotCornerSettings()
    ) {
        self.system = system
        self.pointer = pointer
        self.clock = clock
        self.log = log
        self.settings = settings
    }

    /// Creates a controller that does nothing, for previews and the gallery.
    public convenience init() {
        self.init(system: NoHotCornerSystem(), pointer: NoPointerSource(), clock: ContinuousClock(), log: nil)
    }

    // MARK: - Running

    /// Starts following the settings: watches the pointer if they need it, and looks whether the old app runs.
    public func start() {
        isRunning = true
        refreshLegacyAppRunning()
        updateWatching()
    }

    /// Stops watching and ends a hold. ``start()`` starts again.
    public func stop() {
        isRunning = false
        updateWatching()
    }

    /// Follows changed settings at once: switched off, the watching stops and a hold ends.
    ///
    /// - Parameter settings: the settings now
    public func apply(_ settings: HotCornerSettings) {
        if settings != self.settings {
            self.settings = settings
        }
        updateWatching()
    }

    private func updateWatching() {
        let needed = isRunning && settings.needsWatching
        guard needed != isWatching else {
            return
        }
        isWatching = needed
        if needed {
            pointer.start { [weak self] event in
                self?.handle(event)
            }
        } else {
            pointer.stop()
            endVisit()
        }
    }

    // MARK: - The pointer

    /// Takes one pointer move or drag.
    ///
    /// - Parameter event: the move
    func handle(_ event: PointerEvent) {
        guard isWatching else {
            return
        }
        // A drag into a corner, of a window or a file, fires nothing, and a press ends the visit.
        guard !event.buttonsDown else {
            endVisit()
            return
        }
        lastLocation = event.location
        let corner = HotCornerGeometry.corner(at: event.location, screens: pointer.screens)
        guard corner != currentCorner else {
            return
        }
        endVisit()
        guard let corner else {
            return
        }
        currentCorner = corner
        let delay = settings[corner].delay
        if delay <= 0 {
            delayEnded(in: corner)
            return
        }
        delayTask = Task { [clock, weak self] in
            do {
                try await clock.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.delayEnded(in: corner)
        }
    }

    /// Ends the visit: the wait stops, a hold ends, and the next visit may fire again.
    private func endVisit() {
        delayTask?.cancel()
        delayTask = nil
        if isHolding {
            isHolding = false
            system.endHold()
        }
        visitDone = false
        if currentCorner != nil {
            currentCorner = nil
        }
    }

    private func delayEnded(in corner: HotCorner) {
        guard isWatching, currentCorner == corner, !visitDone else {
            return
        }
        visitDone = true
        let held = pointer.modifiers
        // Two keys or more pick nothing; caps lock and fn never reach here.
        guard held.count <= 1 else {
            return
        }
        let modifier = held.first
        let action = settings[corner][modifier]
        guard action != .none else {
            return
        }
        perform(action)
        showGlowOfFire(in: corner)
        let label = corner.title + (modifier.map { " (\($0.symbol))" } ?? "")
        write("Mega Corner \(label): \(action.logText)")
    }

    /// Plays the glow at the corner of the display the pointer is on, when the glow is on.
    private func showGlowOfFire(in corner: HotCorner) {
        guard settings.glow.enabled, let location = lastLocation else {
            return
        }
        let screens = pointer.screens
        let holding = screens.first { $0.contains(location) } ?? screens.first { $0.insetBy(dx: -1, dy: -1).contains(location) }
        guard let screen = holding else {
            return
        }
        system.showGlow(at: corner, screen: screen, glow: settings.glow)
    }

    private func perform(_ action: HotCornerAction) {
        switch action {
        case .none:
            break
        case .system(let systemAction):
            system.perform(systemAction)
            if systemAction.isHold {
                isHolding = true
            }
        case .runShortcut(let name):
            system.runShortcut(named: name)
        case .openApp(let path):
            system.openApp(at: path)
        case .openSection, .showMainWindow, .search, .refreshNow, .muteAlerts:
            onAppAction?(action)
        }
    }

    // MARK: - Settings' extras

    /// Shows the real glow at a corner of the main display, for Settings' "Try on Screen" (HOT-12), whether or not the
    /// glow is switched on.
    ///
    /// - Parameters:
    ///   - corner: the corner
    ///   - glow: the glow as Settings shows it now
    public func showGlowPreview(at corner: HotCorner, glow: HotCornerGlow) {
        // The first display is the main one, the one with the menu bar.
        guard let screen = pointer.screens.first else {
            return
        }
        var shown = glow
        shown.enabled = true
        system.showGlow(at: corner, screen: screen, glow: shown)
    }

    /// Loads the shortcut names for the Run Shortcut menu, again each time Settings shows the pane.
    public func loadShortcutNames() async {
        let names = await system.shortcutNames()
        if names != shortcutNames {
            shortcutNames = names
        }
    }

    /// Looks again whether the old app runs.
    public func refreshLegacyAppRunning() {
        let running = system.isLegacyAppRunning
        if running != isLegacyAppRunning {
            isLegacyAppRunning = running
        }
    }

    /// Asks the old Hot Corners app to quit, then looks again, at once and a second later, as an app takes a moment to
    /// quit. Never deletes it.
    public func quitLegacyApp() {
        system.quitLegacyApp()
        write("Mega Corners: asked the old Hot Corners app to quit")
        refreshLegacyAppRunning()
        Task { [clock, weak self] in
            try? await clock.sleep(for: .seconds(1))
            self?.refreshLegacyAppRunning()
        }
    }

    // MARK: - The log

    private func write(_ message: String) {
        guard let log else {
            return
        }
        let previous = logTask
        logTask = Task {
            await previous?.value
            await log.log(.info, .app, message)
        }
    }

    #if DEBUG
    /// Waits until the delay under way has ended and the log lines so far are written. Debug builds only.
    func settled() async {
        await delayTask?.value
        await logTask?.value
    }
    #endif
}
