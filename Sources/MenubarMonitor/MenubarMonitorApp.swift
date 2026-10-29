import MenubarCore
import MenubarUI
import SwiftUI

/// The app's scenes (Task 4.1): the menubar item with its pane (`MenuPaneView`, whose flyouts are child windows of
/// its own), the main window, the welcome flow and Settings.
///
/// There is no alert scene: the alert is a panel that `NativeEffects` creates (Task 4.4). Every scene gets the model
/// and the shell's one router through `appEnvironment(_:router:)`.
struct MenubarMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        let shell = delegate.shell
        MenuBarExtra(isInserted: Binding(get: { shell.showInMenuBar }, set: { shell.showInMenuBar = $0 })) {
            MenuPaneView()
                .onAppear { shell.surfaceAppeared() }
                .appEnvironment(shell.model, router: shell.router)
        } label: {
            StatusLabel()
                .capturesWindowActions(for: shell.presenter)
                .appEnvironment(shell.model, router: shell.router)
        }
        .menuBarExtraStyle(.window)

        Window(AppIdentity.name, id: WindowPresenter.mainWindowID) {
            MainWindowRoot()
                .tracksPresence(as: WindowPresenter.mainWindowID, in: shell.presenter)
                .onAppear { shell.surfaceAppeared() }
                .appEnvironment(shell.model, router: shell.router)
        }
        // Never by itself at launch or at login, also while the status item is hidden: only starting the app again
        // opens it (APP-03). SwiftUI uses the same behavior for a click on the Dock icon without windows.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(width: 1120, height: 720)
        .commands {
            MainWindowCommands(model: shell.model, router: shell.router) { openWindow, openSettings in
                shell.presenter.handOver(openWindow: openWindow, openSettings: openSettings)
            }
        }

        // The welcome flow (Task 6.4): opened by AppShell.launch() at first start, never from a menu.
        Window(WelcomePage.windowTitle, id: WindowPresenter.welcomeWindowID) {
            WelcomeView(actions: welcomeActions(shell: shell))
                .tracksPresence(as: WindowPresenter.welcomeWindowID, in: shell.presenter)
                .appEnvironment(shell.model, router: shell.router)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Settings (Task 6.1): its panes in a TabView, each 560 pt wide with a height of its own.
        Settings {
            SettingsView(system: settingsSystem())
                .tracksPresence(as: "settings", in: shell.presenter)
                .appEnvironment(shell.model, router: shell.router)
        }
        .windowResizability(.contentSize)
    }

    /// What Settings asks of the app: the notification permission through `NativeEffects`, for Settings → General's
    /// notification row (APP-04).
    private func settingsSystem() -> SettingsSystem {
        let effects = delegate.effects
        return SettingsSystem(
            notificationPermission: { await effects.notificationPermission() },
            requestNotificationPermission: { _ = await effects.requestNotificationPermission() },
            openNotificationSettings: { effects.openNotificationSettings() })
    }

    /// What the welcome flow asks of the app: the notification permission through `NativeEffects` (APP-04) and the
    /// import of a chosen folder through the shell (IMP-01).
    private func welcomeActions(shell: AppShell) -> WelcomeActions {
        let effects = delegate.effects
        return WelcomeActions(
            notificationPermission: { await effects.notificationPermission() },
            requestNotificationPermission: {
                _ = await effects.requestNotificationPermission()
                return await effects.notificationPermission()
            },
            openNotificationSettings: { effects.openNotificationSettings() },
            importOldFolder: { await shell.importChosenFolder($0) })
    }
}

