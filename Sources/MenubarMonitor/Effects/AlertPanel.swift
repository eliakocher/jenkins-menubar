import AppKit
import MenubarCore
import MenubarUI
import SwiftUI

/// The open alert windows, one per alert (ALERT-03).
///
/// Each shows centered on the main screen, or cascades from the newest one while alerts are open, and stays until a
/// button, Esc, ⌘. or ⌘W closes it.
@MainActor
final class AlertPanels: NSObject, NSWindowDelegate {
    private var panels: [ObjectIdentifier: AlertPanel] = [:]
    /// where the next alert's top left corner goes while alerts are open
    private var cascadePoint: NSPoint?

    /// Shows an alert in a panel of its own, in front of every window, without taking the keyboard.
    ///
    /// - Parameters:
    ///   - alert: the alert
    ///   - notificationsOff: whether it shows because its banner couldn't, which its footnote says
    ///   - rebuild: starts the build's rebuild, for the Rebuild button (PIPE-09)
    ///   - hide: hides the build until its job's next build, for the Hide button (HIDE-01)
    func show(
        _ alert: BuildAlert, notificationsOff: Bool, rebuild: @escaping @MainActor (BuildID) -> Void,
        hide: @escaping @MainActor (BuildID) -> Void
    ) {
        // The system's window lists show the title as it is, so it gets the headline without the emoji (ALERT-03).
        let panel = AlertPanel(title: alert.content.headlineParts?.text ?? alert.content.headline)
        let view = BuildAlertView(alert: alert, notificationsOff: notificationsOff) { [weak panel] action in
            if action == .rebuild, let build = alert.content.rebuild {
                rebuild(build)
            } else if action == .hide, let build = alert.content.hide {
                hide(build)
            } else if let url = alert.content.url(for: action) {
                NSWorkspace.shared.open(url)
            }
            panel?.close()
        }
        panel.setContent(NSHostingView(rootView: view))
        panel.delegate = self
        if let cascadePoint, !panels.isEmpty {
            self.cascadePoint = panel.cascadeTopLeft(from: cascadePoint)
        } else {
            panel.center()
            cascadePoint = panel.cascadeTopLeft(from: .zero)
        }
        panels[ObjectIdentifier(panel)] = panel
        // Never makeKeyAndOrderFront or activate: typing in another app goes on (ALERT-03).
        panel.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? AlertPanel else {
            return
        }
        panel.delegate = nil
        panels[ObjectIdentifier(panel)] = nil
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

    /// Esc and ⌘. dismiss the alert once it is key.
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    /// ⌘W, through the menu's Close or ``performKeyEquivalent(with:)``, dismisses the alert: without a close button,
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
