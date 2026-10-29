import AppKit
import MenubarCore
import Observation
import SwiftUI

/// Opens the main window and Settings, and switches the activation policy as Task 0.11 decided (APP-01).
///
/// - Every action that opens a window goes through ``showMainWindow()`` or ``showSettings()``, which set the regular
///   policy *before* opening and activate after it. Set afterwards, the menu bar keeps the previous app's menus. The
///   views reach them through the app's `WindowRouter`, whose closure `AppShell` builds.
/// - The windows report themselves through ``tracksPresence(as:in:)``; when the last one closes, the app goes back to
///   the accessory policy: no Dock icon, no ⌘-Tab entry. The panel and the alert window never report.
///
/// SwiftUI hands out `openWindow` and `openSettings` only to views, so every scene's view passes them in through
/// ``capture(openWindow:openSettings:)``. The menubar label does it at launch (Task 0.10 verified it works before the
/// panel ever opened). With "Show in menu bar" off no view has appeared, and no window opens at launch (APP-03), so a
/// window asked for before then waits, and the presenter performs the Window menu's "menubar-monitor" command, whose
/// view reads both actions from its environment and hands them over (``handOver(openWindow:openSettings:)``); the
/// waiting window then opens.
///
/// What the windows show (the watch request, the Settings pane) isn't kept here: the router holds the watch request
/// and the settings store the pane.
@MainActor
@Observable
final class WindowPresenter {
    /// the scene id of the main window
    static let mainWindowID = "main"
    /// the scene id of the welcome flow's window (Task 6.4)
    static let welcomeWindowID = "welcome"

    @ObservationIgnored private var openWindow: OpenWindowAction?
    @ObservationIgnored private var openSettings: OpenSettingsAction?
    @ObservationIgnored private var presence = DockPresence()
    /// A window asked for before any view handed over SwiftUI's actions.
    private enum PendingWindow {
        case main
        case welcome
        case settings
    }

    /// the window that waits for SwiftUI's actions; `nil` for none
    @ObservationIgnored private var pending: PendingWindow?
    /// whether the Window menu's command runs for a waiting window, so a command that didn't hand anything over can't
    /// start itself again
    @ObservationIgnored private var isAskingMenu = false

    /// whether the main window, Settings or the welcome flow is open
    var hasOpenWindow: Bool {
        presence.showsDockIcon
    }

    /// Keeps SwiftUI's actions to open windows, from any view that has them, and opens the window that waited for them.
    func capture(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        _ = handOver(openWindow: openWindow, openSettings: openSettings)
    }

    /// Keeps SwiftUI's actions to open windows, which the Window menu's "menubar-monitor" command hands over when it is
    /// performed, and opens the window that waited for them.
    ///
    /// - Returns: whether a window waited; the command then opens nothing else
    func handOver(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) -> Bool {
        self.openWindow = openWindow
        self.openSettings = openSettings
        guard let pending else {
            return false
        }
        self.pending = nil
        switch pending {
        case .main: showMainWindow()
        case .welcome: showWelcome()
        case .settings: showSettings()
        }
        return true
    }

    /// Opens the welcome flow and gives it the keyboard, at launch (Task 6.4; `welcome.md`, Unverified 1).
    func showWelcome() {
        guard let openWindow else {
            wait(for: .welcome)
            return
        }
        NSApp.setActivationPolicy(.regular)
        openWindow(id: Self.welcomeWindowID)
        NSApp.activate()
    }

    /// whether the main window is the one in front: the app is active and the main window has the keyboard
    var isMainWindowFront: Bool {
        guard NSApp.isActive, !NSApp.isHidden, let window = NSApp.keyWindow else {
            return false
        }
        return window.identifier?.rawValue.contains(Self.mainWindowID) == true || window.title == AppIdentity.name
    }

    /// Opens the main window, or brings it forward, and gives it the keyboard.
    func showMainWindow() {
        guard let openWindow else {
            wait(for: .main)
            return
        }
        NSApp.setActivationPolicy(.regular)
        // After the global hotkey hid the app (APP-08), the window comes back with it.
        NSApp.unhide(nil)
        openWindow(id: Self.mainWindowID)
        NSApp.activate()
    }

    /// Opens Settings, or brings it forward. The pane it shows is the settings store's `selectedPane`.
    func showSettings() {
        guard let openSettings else {
            wait(for: .settings)
            return
        }
        NSApp.setActivationPolicy(.regular)
        openSettings()
        NSApp.activate()
    }

    /// Keeps a window until SwiftUI's actions arrive, and asks the Window menu's "menubar-monitor" command for them.
    /// When the menu has no such command yet, the window opens as soon as any view hands the actions over.
    private func wait(for window: PendingWindow) {
        pending = window
        guard !isAskingMenu else {
            return
        }
        guard let item = Self.mainWindowMenuItem(in: NSApp.mainMenu), let menu = item.menu else {
            AppLog.warning("No view has handed over SwiftUI's window actions yet, and the Window menu has no "
                + "\(AppIdentity.name) item; the window opens once a view appears")
            return
        }
        isAskingMenu = true
        defer { isAskingMenu = false }
        menu.performActionForItem(at: menu.index(of: item))
    }

    /// Returns the Window menu's "menubar-monitor" item (⌘0), which `MainWindowCommands` puts there.
    private static func mainWindowMenuItem(in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title == AppIdentity.name, item.keyEquivalent == "0", item.submenu == nil {
                return item
            }
            if let found = mainWindowMenuItem(in: item.submenu) {
                return found
            }
        }
        return nil
    }

    /// Notes that a window appeared; the safety net for a window that opened without the helpers above.
    func windowAppeared(_ name: String) {
        presence.opened(name)
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// Notes that a window disappeared; after the last one, the app leaves the Dock and ⌘-Tab.
    func windowDisappeared(_ name: String) {
        presence.closed(name)
        if !presence.showsDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

extension View {
    /// Reports the window this view fills to the presenter, so the app shows a Dock icon while it is open (APP-01), and
    /// hands over SwiftUI's actions to open windows.
    ///
    /// - Parameters:
    ///   - name: the window's name, like `main` or `settings`
    ///   - presenter: the presenter
    func tracksPresence(as name: String, in presenter: WindowPresenter) -> some View {
        modifier(PresenceTracking(name: name, presenter: presenter))
    }

    /// Hands over SwiftUI's actions to open windows, from a view that isn't a window of its own, like the menubar
    /// label.
    func capturesWindowActions(for presenter: WindowPresenter) -> some View {
        modifier(WindowActionCapture(presenter: presenter))
    }
}

private struct PresenceTracking: ViewModifier {
    let name: String
    let presenter: WindowPresenter

    func body(content: Content) -> some View {
        content
            .capturesWindowActions(for: presenter)
            .onAppear { presenter.windowAppeared(name) }
            .onDisappear { presenter.windowDisappeared(name) }
    }
}

private struct WindowActionCapture: ViewModifier {
    let presenter: WindowPresenter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear { presenter.capture(openWindow: openWindow, openSettings: openSettings) }
    }
}
