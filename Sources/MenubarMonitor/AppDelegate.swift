import AppKit
import MenubarCore
import MenubarUI
import UserNotifications

/// The AppKit side of the app (Task 4.1): the activation policy at launch, the notification delegate, the
/// `menubar-monitor://` links, starting the app again, and quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let effects = NativeEffects()
    private(set) lazy var shell = Self.makeShell(effects: effects)
    /// The banners' Rebuild waits for the launch inside the shell, so a click that starts the app rebuilds too
    /// (PIPE-09).
    private lazy var notifications = NotificationDelegate(
        rebuild: { [weak self] build in
            self?.shell.rebuild(build)
        },
        hide: { [weak self] build in
            self?.shell.hide(build)
        },
        open: { [weak self] url, inApp in
            self?.shell.open(url, inApp: inApp)
        })

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Installed before launching finishes, so a link that starts the app reaches it too.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        if NativeEffects.canNotify {
            // Set before launching finishes, so a banner click that starts the app is delivered (ALERT-08).
            UNUserNotificationCenter.current().delegate = notifications
        }
        effects.onRebuild = { [weak self] build in
            self?.shell.rebuild(build)
        }
        effects.onHide = { [weak self] build in
            self?.shell.hide(build)
        }
        effects.onOpen = { [weak self] url, inApp in
            self?.shell.open(url, inApp: inApp)
        }
        // No window opens at launch, also while the status item is hidden: the app stays out of the Dock until a
        // second start opens the main window (APP-01, APP-03).
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NativeEffects.registerBannerCategories()
        shell.launch()
    }

    /// Starting the app again, or clicking its Dock icon: brings the app forward, and opens the main window when none
    /// is open (APP-03).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if shell.presenter.hasOpenWindow {
            NSApp.activate()
        } else {
            shell.router.open(.main)
        }
        return false
    }

    /// The app lives in the menu bar: closing the last window doesn't quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        shell.stop()
    }

    private static func makeShell(effects: NativeEffects) -> AppShell {
        #if DEBUG
        if CommandLine.arguments.contains(AppShell.throwawayOption) {
            return .throwaway(effects: effects)
        }
        #endif
        return .standard(effects: effects)
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let link = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: link)
        else {
            return
        }
        if let route = AppRoute(url: url) {
            shell.open(route)
        } else if ["http", "https"].contains(url.scheme?.lowercased()) {
            // A web link, which macOS sends to the default browser (APP-09).
            shell.openLink(url)
        }
    }
}
