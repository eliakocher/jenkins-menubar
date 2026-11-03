import AppKit
import MenubarCore
import MenubarUI
import SwiftUI

/// The alert window (ALERT-03): one at a time, which holds every alert that came while it was open.
///
/// It shows centered on the main screen, with the newest alert as its first page; an alert that comes while it is open
/// joins it and is shown at once. "1 of 3" and the arrows page through the alerts, Dismiss takes the shown page and
/// shows the next, Dismiss All closes the window, and so do the last page's buttons. The window stays until a button,
/// Esc, ⌘. or ⌘W closes it. Its height follows the page, with the top left corner fixed.
@MainActor
final class AlertPanels: NSObject, NSWindowDelegate {
    private var panel: AlertPanel?
    private let model = AlertPanelModel()
    /// the buttons' effects, those of the newest `show`
    private var effects: Effects?

    /// the effects of the alert window's buttons
    private struct Effects {
        var rebuild: @MainActor (BuildID) -> Void
        var hide: @MainActor (BuildID) -> Void
        var open: @MainActor (URL, Bool) -> Void
        var rebuildWithChanges: @MainActor (BuildID) -> Void
    }

    /// Shows an alert in the window, in front of every window, without taking the keyboard; the window opens for the first
    /// alert and takes the later ones as pages.
    ///
    /// - Parameters:
    ///   - alert: the alert
    ///   - notificationsOff: whether it shows because its banner couldn't, which its footnote says
    ///   - rebuild: starts the build's rebuild, for the Rebuild button (PIPE-09)
    ///   - rebuildWithChanges: opens the "Rebuild with Changes…" sheet for the build (PIPE-09)
    ///   - hide: hides the build until its job's next build, for the Hide button (HIDE-01)
    ///   - open: shows a link in the app (`true`) or opens it in the browser (`false`)
    func show(
        _ alert: BuildAlert, notificationsOff: Bool, rebuild: @escaping @MainActor (BuildID) -> Void,
        rebuildWithChanges: @escaping @MainActor (BuildID) -> Void, hide: @escaping @MainActor (BuildID) -> Void,
        open: @escaping @MainActor (URL, Bool) -> Void
    ) {
        effects = Effects(rebuild: rebuild, hide: hide, open: open, rebuildWithChanges: rebuildWithChanges)
        model.pages.add(alert, notificationsOff: notificationsOff)
        if let panel {
            panel.title = Self.title(of: alert)
            // Never makeKeyAndOrderFront or activate: typing in another app goes on (ALERT-03).
            panel.orderFrontRegardless()
            return
        }
        // The system's window lists show the title as it is, so it gets the headline without the emoji (ALERT-03).
        let panel = AlertPanel(title: Self.title(of: alert))
        let view = BuildAlertPanelView(
            model: model,
            rebuildWithChanges: { [weak self] alert in
                if alert.content.offersRebuild, let build = alert.content.rebuild {
                    self?.effects?.rebuildWithChanges(build)
                }
                self?.dismiss(alert)
            },
            perform: { [weak self] alert, action in self?.perform(action, for: alert) },
            dismissAll: { [weak self] in self?.dismissAll() },
            onSizeChange: { [weak panel] size in panel?.fit(to: size) })
        let hosting = NSHostingView(rootView: view)
        // The panel keeps `.titled` (so it can become key) with a hidden title bar; without this the content honours
        // that title bar's safe area and starts ~28 pt down, leaving an untinted strip of glass at the top.
        hosting.safeAreaRegions = []
        panel.setContent(hosting)
        panel.delegate = self
        // Esc takes the shown page, like the Dismiss button it presses; ⌘W takes the whole window.
        panel.onCancel = { [weak self] in
            if let id = self?.model.pages.current?.id {
                self?.dismiss(id)
            }
        }
        panel.center()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private static func title(of alert: BuildAlert) -> String {
        alert.content.headlineParts?.text ?? alert.content.headline
    }

    /// Runs a button of a page, then dismisses the page.
    private func perform(_ action: AlertContent.Action, for alert: BuildAlert) {
        if action == .rebuild, alert.content.offersRebuild, let build = alert.content.rebuild {
            effects?.rebuild(build)
        } else if action == .hide, let build = alert.content.hide {
            effects?.hide(build)
        } else if let url = alert.content.url(for: action) {
            // Show Build and Show MR stay in the app; a preview's made-up build has nothing to show there.
            effects?.open(url, action.showsInApp && alert.content.isLive)
        }
        dismiss(alert)
    }

    private func dismiss(_ alert: BuildAlert) {
        dismiss(alert.id)
    }

    /// Takes a page out; the window closes with the last one.
    private func dismiss(_ id: UUID) {
        model.pages.dismiss(id)
        if model.pages.isEmpty {
            panel?.close()
        } else if let current = model.pages.current {
            panel?.title = Self.title(of: current.alert)
        }
    }

    private func dismissAll() {
        model.pages.dismissAll()
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? AlertPanel, closing === panel else {
            return
        }
        closing.delegate = nil
        // A close by ⌘W or the system leaves no page behind, so the next alert opens a fresh window.
        model.pages.dismissAll()
        panel = nil
    }
}

/// The window of one alert: a non-activating glass panel without window buttons that floats over other apps, every
/// Space and full-screen apps, and becomes key only when it's clicked (`docs/design/alert.md`, panel configuration,
/// and the user's decision Q7).
final class AlertPanel: NSPanel {
    /// the glass's corners, which are the window's corners too: the clear window draws none of its own
    private static let cornerRadius: CGFloat = 16

    init(title: String) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
            // `.titled` stays without a title bar to show: a window can become key only with it, so a click makes the
            // alert usable. Not closable, since there is no close button.
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        self.title = title
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        // The glass is the whole background: the window itself draws nothing, but keeps its shadow.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
    }

    /// what Esc does; the window's own close is for ⌘W
    var onCancel: (() -> Void)?

    /// Shows the alert's view on the panel's glass and sizes the panel to fit it.
    ///
    /// - Parameter view: the hosted `BuildAlertView`
    func setContent(_ view: NSView) {
        let size = view.fittingSize
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.style = .regular
        glass.cornerRadius = Self.cornerRadius
        view.frame = glass.bounds
        view.autoresizingMask = [.width, .height]
        glass.contentView = view
        contentView = glass
        setContentSize(size)
    }

    /// Gives the panel a new content size, keeping its top left corner where it is: the pages of an alert window differ
    /// in height, and a window that grew from its bottom would jump.
    ///
    /// - Parameter size: the content's size
    func fit(to size: CGSize) {
        guard size.width > 0, size.height > 0, abs(contentRect(forFrameRect: frame).height - size.height) > 0.5 else {
            return
        }
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        let target = frameRect(forContentRect: NSRect(origin: .zero, size: size))
        setFrame(
            NSRect(x: topLeft.x, y: topLeft.y - target.height, width: target.width, height: target.height), display: true,
            animate: false)
    }

    /// Esc and ⌘. dismiss the shown alert once the panel is key.
    override func cancelOperation(_ sender: Any?) {
        if let onCancel {
            onCancel()
        } else {
            close()
        }
    }

    /// ⌘W, through the menu's Close or ``performKeyEquivalent(with:)``, dismisses every alert of the window: without a close button,
    /// `NSWindow` would only beep.
    override func performClose(_ sender: Any?) {
        close()
    }

    /// ⌘W dismisses the alert once it is key, also while another app is active and the app's menu doesn't get the key.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
