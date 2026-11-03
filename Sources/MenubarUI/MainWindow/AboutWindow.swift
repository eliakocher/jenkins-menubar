import AppKit
import MenubarCore
import SwiftUI

/// The About window: one window, brought forward when it is already open (EGG-21).
@MainActor
enum AboutWindow {
    private static var window: NSWindow?
    private static var closer: (any NSObjectProtocol)?

    /// Opens the window, or brings the open one to the front, with the credits as the easter eggs setting has them.
    ///
    /// - Parameters:
    ///   - eggs: whether the easter eggs are on
    ///   - model: the app, for the peeking butler and the count of the catches
    static func show(eggs: Bool, model: AppModel? = nil) {
        let root = AboutView(
            eggs: eggs, icon: NSApp.applicationIconImage,
            versionLine: AboutCredits.versionLine(info: Bundle.main.infoDictionary), model: model)
        if let window {
            if let host = window.contentViewController as? NSHostingController<AboutView>, host.rootView.eggs != eggs {
                host.rootView = root
                window.setContentSize(AboutView.size(eggs: eggs))
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.title = "About \(AppIdentity.displayName)"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.setContentSize(AboutView.size(eggs: eggs))
        window.center()
        Self.window = window
        closer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Self.window = nil
                if let closer = Self.closer {
                    NotificationCenter.default.removeObserver(closer)
                }
                Self.closer = nil
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
