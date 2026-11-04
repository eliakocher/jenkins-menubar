import AppKit

/// Owns the tooltips of every window: one ``TipController`` per window, and one `NSEvent` monitor for all of them.
@MainActor
final class TipHub {
    static let shared = TipHub()

    private var controllers: [ObjectIdentifier: TipController] = [:]
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    func register(_ anchor: TipAnchorView, in window: NSWindow) {
        controller(for: window).add(anchor)
    }

    func unregister(_ anchor: TipAnchorView, from window: NSWindow) {
        controllers[ObjectIdentifier(window)]?.remove(anchor)
    }

    /// Returns the controller of a window that has anchors, for the tests.
    func existingController(for window: NSWindow) -> TipController? {
        controllers[ObjectIdentifier(window)]
    }

    private func controller(for window: NSWindow) -> TipController {
        let id = ObjectIdentifier(window)
        if let existing = controllers[id] {
            return existing
        }
        let controller = TipController(window: window) { [weak self] in
            self?.controllers[id] = nil
        }
        controllers[id] = controller
        installMonitor()
        return controller
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let kind = event.type
            let window = event.window
            let location = event.locationInWindow
            MainActor.assumeIsolated { self?.handle(kind, in: window, at: location) }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controllers.values.forEach { $0.interrupt() }
            }
        }
    }

    /// Passes an event on to the controller of its window; the others lose their pointer.
    private func handle(_ kind: NSEvent.EventType, in target: NSWindow?, at location: NSPoint) {
        for controller in controllers.values where controller.window !== target {
            controller.interrupt()
        }
        guard let target, let controller = controllers[ObjectIdentifier(target)] else { return }
        switch kind {
        case .mouseMoved:
            controller.pointerMoved(at: location)
        case .scrollWheel:
            controller.scrolled(at: location)
        default:
            // a click or a key
            controller.interrupt()
        }
    }
}

/// The tooltip of one window: tracks the pointer with the hub's monitor, asks ``TipTiming`` when to show, finds the area
/// under the pointer among the registered anchors only then, and moves, fills and shows its one ``TipBubble``.
///
/// No timer per view and no hover state per view: while the pointer moves, the cost is a timestamp, and while the page
/// scrolls, nothing at all.
@MainActor
final class TipController {
    private(set) weak var window: NSWindow?
    private let anchors = NSHashTable<TipAnchorView>.weakObjects()
    private var timing = TipTiming()
    private var timer: Timer?
    /// the pointer in the window's coordinates, from the last move or scroll event
    private var pointer: NSPoint?
    /// whether a tooltip shows only while the app is the active one; the tests switch it off
    var requiresActiveApp = true
    private(set) weak var shownAnchor: TipAnchorView?
    private let bubble = TipBubble()
    private let exitView = TipExitView()
    private var closeObserver: NSObjectProtocol?
    private let onClose: () -> Void

    init(window: NSWindow, onClose: @escaping () -> Void) {
        self.window = window
        self.onClose = onClose
        // The monitor gets the moves only when the window asks for them.
        window.acceptsMouseMovedEvents = true
        exitView.onExit = { [weak self] in self?.interrupt() }
        if let content = window.contentView {
            exitView.frame = content.bounds
            exitView.autoresizingMask = [.width, .height]
            content.addSubview(exitView)
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func close() {
        interrupt()
        exitView.removeFromSuperview()
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        onClose()
    }

    func add(_ anchor: TipAnchorView) {
        anchors.add(anchor)
    }

    func remove(_ anchor: TipAnchorView) {
        anchors.remove(anchor)
    }

    // MARK: Events

    func pointerMoved(at location: NSPoint, now: Date = Date()) {
        pointer = location
        let inShown = shownAnchor.flatMap(frame(of:))?.contains(location) ?? false
        if timing.pointerMoved(at: now, inShownArea: inShown) {
            hide()
        }
        scheduleIfWaiting(now: now)
    }

    func scrolled(at location: NSPoint? = nil, now: Date = Date()) {
        if let location { pointer = location }
        if timing.scrolled(at: now) {
            hide()
        }
        scheduleIfWaiting(now: now)
    }

    func interrupt() {
        if timing.interrupted() {
            hide()
        }
        timer?.invalidate()
        timer = nil
    }

    // MARK: Timing

    /// One timer, started when a tooltip becomes due; later moves only move the rest's start, and the timer looks again
    /// when it fires.
    private func scheduleIfWaiting(now: Date) {
        guard timer == nil, timing.isWaiting, let wait = timing.delayLeft(at: now) else { return }
        schedule(after: wait)
    }

    private func schedule(after wait: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: max(wait, 0.01), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
    }

    private func timerFired() {
        timer = nil
        guard let left = timing.delayLeft(at: Date()) else { return }
        if left > 0.005 {
            schedule(after: left)
        } else {
            show()
        }
    }

    // MARK: Showing

    private func show() {
        guard let window, window.isVisible, !requiresActiveApp || NSApp.isActive else {
            timing.nothingToShow()
            return
        }
        let point = pointer ?? window.mouseLocationOutsideOfEventStream
        guard let hit = resolve(at: point) else {
            timing.nothingToShow()
            return
        }
        bubble.present(hit.source, pointer: window.convertPoint(toScreen: point), in: window)
        shownAnchor = hit.anchor
        timing.didShow()
    }

    /// Returns the anchor and the tooltip under a point of the window: the innermost anchor of those that are on screen
    /// right now. Every frame is read and converted here, never kept, so a page that scrolled or moved is seen as it is.
    ///
    /// - Parameter point: the point, in the window's coordinates
    func resolve(at point: NSPoint) -> (anchor: TipAnchorView, source: TipSource)? {
        var candidates: [TipAnchorView] = []
        var areas: [TipArea] = []
        for anchor in anchors.allObjects where anchor.source != nil {
            guard let frame = frame(of: anchor) else { continue }
            areas.append(TipArea(id: candidates.count, frame: frame, depth: anchor.depthInWindow))
            candidates.append(anchor)
        }
        guard let hit = TipHitTest.area(at: point, in: areas), let source = candidates[hit.id].source else { return nil }
        return (candidates[hit.id], source)
    }

    private func hide() {
        bubble.hide()
        shownAnchor = nil
    }

    /// Returns the part of an anchor that is on screen, in the window's coordinates; `nil` for one that is in another
    /// window, hidden (itself or an ancestor, or fully transparent) or scrolled out.
    private func frame(of anchor: TipAnchorView) -> CGRect? {
        guard anchor.window === window else { return nil }
        return anchor.frameOnScreen
    }
}

/// A view over the window's content that takes no clicks and only tells when the pointer leaves the window.
@MainActor
private final class TipExitView: NSView {
    var onExit: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }
}
