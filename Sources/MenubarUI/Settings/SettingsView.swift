import MenubarCore
import SwiftUI

/// What Settings needs from the app that the views can't do themselves: the notification permission, which only the
/// app's bundle can read and ask for (APP-04).
public struct SettingsSystem {
    /// reads whether macOS shows the app's banners
    public var notificationPermission: @MainActor () async -> NotificationPermission
    /// asks macOS for the permission, banners and sounds; macOS asks only once
    public var requestNotificationPermission: @MainActor () async -> Void
    /// opens the app's pane in System Settings → Notifications
    public var openNotificationSettings: @MainActor () -> Void
    /// the opt-in link router behind Settings → General's "Open GitLab and Jenkins Links" switch (APP-09); `nil` hides it
    public var linkRouting: LinkRouting?

    public init(
        notificationPermission: @escaping @MainActor () async -> NotificationPermission,
        requestNotificationPermission: @escaping @MainActor () async -> Void,
        openNotificationSettings: @escaping @MainActor () -> Void,
        linkRouting: LinkRouting? = nil
    ) {
        self.linkRouting = linkRouting
        self.notificationPermission = notificationPermission
        self.requestNotificationPermission = requestNotificationPermission
        self.openNotificationSettings = openNotificationSettings
    }
}

/// The Settings scene's content (Task 6.1, `docs/design/settings.md`): a `TabView` with one tab per pane, in the order
/// of ``SettingsPane``, bound to `SettingsStore.selectedPane`, which the routes set before Settings opens and which
/// UserDefaults keeps, so Settings opens at the pane it showed last.
///
/// Every pane is 560 pt wide and as high as its content, so the window takes each pane's height; only content taller
/// than the screen scrolls inside the pane's form. Closing the window saves the team values that wait for typing to
/// pause. It reads the stores and the router from the environment (``SwiftUICore/View/appEnvironment(_:router:)``).
public struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    private let system: SettingsSystem

    /// - Parameter system: the app's notification permission
    public init(system: SettingsSystem) {
        self.system = system
    }

    public var body: some View {
        @Bindable var settings = settings
        TabView(selection: $settings.selectedPane) {
            Tab(SettingsPane.general.title, systemImage: SettingsPane.general.symbol, value: SettingsPane.general) {
                GeneralPane(system: system)
                    .settingsPaneFrame(.general)
            }
            Tab(SettingsPane.jenkins.title, systemImage: SettingsPane.jenkins.symbol, value: SettingsPane.jenkins) {
                JenkinsPane()
                    .settingsPaneFrame(.jenkins)
            }
            Tab(SettingsPane.gitLab.title, systemImage: SettingsPane.gitLab.symbol, value: SettingsPane.gitLab) {
                GitLabPane()
                    .settingsPaneFrame(.gitLab)
            }
            Tab(
                SettingsPane.repositories.title, systemImage: SettingsPane.repositories.symbol,
                value: SettingsPane.repositories
            ) {
                RepositoriesPane()
                    .settingsPaneFrame(.repositories)
            }
            Tab(SettingsPane.team.title, systemImage: SettingsPane.team.symbol, value: SettingsPane.team) {
                TeamPane()
                    .settingsPaneFrame(.team)
            }
            Tab(SettingsPane.accounts.title, systemImage: SettingsPane.accounts.symbol, value: SettingsPane.accounts) {
                AccountsPane()
                    .settingsPaneFrame(.accounts)
            }
        }
        .onDisappear {
            settings.saveTeamNow()
        }
    }
}

extension SettingsPane {
    /// the pane toolbar's SF Symbol, the app's vocabulary: `hammer` is Pipelines, `arrow.triangle.pull` Merge
    /// Requests
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .jenkins: "hammer"
        case .gitLab: "arrow.triangle.pull"
        case .repositories: "arrow.triangle.branch"
        case .team: "person.2"
        case .accounts: "person.crop.circle"
        }
    }
}

extension View {
    /// A pane's size in the Settings window: 560 pt wide, as high as its content up to the screen's height.
    func settingsPaneFrame(_ pane: SettingsPane) -> some View {
        settingsPaneFrame(estimate: SettingsMetrics.estimate(of: pane))
    }

    /// A pane's size in the Settings window, starting at an estimated height until the form has measured itself.
    func settingsPaneFrame(estimate: CGFloat) -> some View {
        modifier(SettingsPaneFrame(estimate: estimate))
    }
}
