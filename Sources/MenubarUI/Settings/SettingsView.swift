import AppKit
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
    /// shows the welcome flow again, for Settings → Advanced's "Show Welcome…"; `nil` hides it
    public var showWelcome: (@MainActor () -> Void)?

    public init(
        notificationPermission: @escaping @MainActor () async -> NotificationPermission,
        requestNotificationPermission: @escaping @MainActor () async -> Void,
        openNotificationSettings: @escaping @MainActor () -> Void,
        linkRouting: LinkRouting? = nil,
        showWelcome: (@MainActor () -> Void)? = nil
    ) {
        self.linkRouting = linkRouting
        self.showWelcome = showWelcome
        self.notificationPermission = notificationPermission
        self.requestNotificationPermission = requestNotificationPermission
        self.openNotificationSettings = openNotificationSettings
    }
}

/// The Settings scene's content: System Settings' sidebar with its search and the selected pane, bound to
/// `SettingsStore.selectedPane`, which the routes set before Settings opens and which UserDefaults keeps, so Settings
/// opens at the pane it showed last.
///
/// The window has a size of its own, not its panes' heights: each pane's form scrolls. Closing the window saves the
/// team values that wait for typing to pause. It reads the stores and the router from the environment
/// (``SwiftUICore/View/appEnvironment(_:router:)``).
public struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @ViewState private var query = ""
    private let system: SettingsSystem

    /// - Parameter system: the app's notification permission
    public init(system: SettingsSystem) {
        self.system = system
    }

    public var body: some View {
        @Bindable var settings = settings
        SettingsShell(selection: $settings.selectedPane, query: $query, onReveal: { settings.reveal($0) }) { pane in
            switch pane {
            case .general: GeneralPane(system: system)
            case .menuBar: MenuBarPane()
            case .notifications: NotificationsPane(system: system)
            case .appearance: AppearancePane()
            case .shortcuts: ShortcutsPane()
            case .accounts: AccountsPane()
            case .projects: ProjectsPane()
            case .team: TeamPane()
            case .pipelines: JenkinsPane()
            case .workItems: GitLabPane()
            case .workspaces: RepositoriesPane()
            case .claude: ClaudePane()
            case .advanced: AdvancedPane(system: system)
            }
        }
        .butlerPeek()
        .onDisappear {
            settings.saveTeamNow()
        }
    }
}

/// The sidebar with its search and the selected pane, drawn only from what it is given, so the gallery shows it with
/// fixed panes.
struct SettingsShell<Detail: View>: View {
    @Binding var selection: SettingsPane
    @Binding var query: String
    /// called with the field of a search result a click opens, which the app scrolls to and highlights
    var onReveal: (SettingsField) -> Void = { _ in }
    @ViewBuilder let detail: (SettingsPane) -> Detail

    var body: some View {
        NavigationSplitView {
            List(selection: listSelection) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group, id: \.self) { pane in
                            SettingsSidebarRow(pane: pane)
                                .tag(pane)
                            ForEach(matchingFields(of: pane), id: \.self) { field in
                                SettingsSidebarFieldRow(field: field) { onReveal(field) }
                            }
                        }
                    }
                }
            }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: Text("Search"))
            .navigationSplitViewColumnWidth(SettingsMetrics.sidebarWidth)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(selection)
                // The window's title is the pane's name, for the Window menu and accessibility; it isn't drawn (see
                // ``ResizableSettingsWindow``): the pane's header card names it (the user, 2026-11-02).
                .navigationTitle(selection.title)
                // The title is hidden and nothing lives in the detail's toolbar (the sidebar's search sits in the
                // sidebar, the traffic lights over it), but the toolbar still reserves its ~66 pt as a top safe area,
                // so the header card started ~96 pt down. Ignoring it lets the card sit ~30 pt down, its group about
                // 20 pt, as in System Settings. The form was already full height under the toolbar, so the window
                // still drags by its titlebar and the content scrolls beneath it; the soft edge fades it there.
                .ignoresSafeArea(.container, edges: .top)
                .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .background(ResizableSettingsWindow())
        .onChange(of: query) {
            // The pane follows the search, as System Settings' does, while the shown one no longer matches.
            if !paneMatches(selection), let first = groups.first?.first {
                selection = first
            }
        }
        .frame(
            minWidth: SettingsMetrics.minimumWindow.width, idealWidth: SettingsMetrics.window.width,
            maxWidth: .infinity, minHeight: SettingsMetrics.minimumWindow.height,
            idealHeight: SettingsMetrics.window.height, maxHeight: .infinity)
    }

    /// the sidebar's groups with the panes that match the search, empty groups left out
    private var groups: [[SettingsPane]] {
        SettingsPane.groups.map { $0.filter(paneMatches) }.filter { !$0.isEmpty }
    }

    /// whether the pane or one of its fields matches the search
    private func paneMatches(_ pane: SettingsPane) -> Bool {
        pane.matches(query) || !matchingFields(of: pane).isEmpty
    }

    /// the pane's fields that match the search, listed under its row; none without a search
    private func matchingFields(of pane: SettingsPane) -> [SettingsField] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return SettingsField.fields(of: pane).filter { $0.matches(query) }
    }

    /// The list's selection is optional; a click on nothing keeps the pane.
    private var listSelection: Binding<SettingsPane?> {
        Binding(get: { selection }, set: { if let pane = $0 { selection = pane } })
    }
}

/// A search result under its pane's sidebar row: a field's title, indented and smaller, that opens the pane at the
/// field. A button, not a selection of the list.
struct SettingsSidebarFieldRow: View {
    let field: SettingsField
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: field.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(field.pane.title) at \(field.title)")
    }
}

/// A sidebar row: the pane's symbol, white in a colored rounded square, and its title, as System Settings draws them.
struct SettingsSidebarRow: View {
    let pane: SettingsPane

    var body: some View {
        Label {
            Text(verbatim: pane.title)
        } icon: {
            Image(systemName: pane.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

extension SettingsPane {
    /// the sidebar's SF Symbol, the app's vocabulary where a section has one: `hammer` is Pipelines, `checklist` Work
    /// Items, `arrow.triangle.branch` Workspaces
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .menuBar: "menubar.rectangle"
        case .notifications: "bell.badge.fill"
        case .appearance: "paintpalette.fill"
        case .shortcuts: "keyboard.fill"
        case .accounts: "key.fill"
        case .projects: "shippingbox.fill"
        case .team: "person.2.fill"
        case .pipelines: "hammer.fill"
        case .workItems: "checklist"
        case .workspaces: "arrow.triangle.branch"
        case .claude: "sparkles"
        case .advanced: "wrench.and.screwdriver.fill"
        }
    }

    /// the color of the sidebar icon's square
    var tint: Color {
        switch self {
        case .general, .advanced: .gray
        case .menuBar: .cyan
        case .notifications: .red
        case .appearance: .indigo
        case .shortcuts: .pink
        case .accounts: .blue
        case .projects: .orange
        case .team: .teal
        case .pipelines: .green
        case .workItems: .purple
        case .workspaces: .brown
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        }
    }
}

/// Makes the Settings window resizable, at least ``SettingsMetrics/minimumWindow``, and remembers its frame. The
/// Settings scene's window comes without a resize handle and SwiftUI may take one away again on an update, so the hook
/// puts it back at every layout. The frame is saved under a name of its own: the old tabbed window's small frame isn't
/// restored, and the first opening gets ``SettingsMetrics/window``, centered.
struct ResizableSettingsWindow: NSViewRepresentable {
    static let autosaveName = "MegaMonitor Settings Window"

    func makeNSView(context: Context) -> NSView {
        WindowHook()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowHook: NSView {
        private weak var configured: NSWindow?
        /// the window's notifications that put the resize handle back; SwiftUI takes it away after a frame change
        nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== configured else { return }
            configured = window
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification]
                .map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated {
                            if let window = self?.window {
                                Self.makeResizable(window)
                            }
                        }
                    }
                }
            Self.makeResizable(window)
            // SwiftUI restores the Settings window's last frame itself, after this; ``grow(_:)`` fixes a small one.
            if !window.setFrameUsingName(ResizableSettingsWindow.autosaveName) {
                window.setContentSize(SettingsMetrics.window)
                window.center()
            }
            window.setFrameAutosaveName(ResizableSettingsWindow.autosaveName)
        }

        override func layout() {
            super.layout()
            if let window {
                Self.makeResizable(window)
                Self.grow(window)
            }
        }

        private static func makeResizable(_ window: NSWindow) {
            // One title only (the user, 2026-11-02): the pane's header card names it, so the window doesn't draw its
            // own title; it stays set for the Window menu and accessibility.
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
            if !window.styleMask.contains(.resizable) {
                window.styleMask.insert(.resizable)
            }
            if window.contentMinSize != SettingsMetrics.minimumWindow {
                window.contentMinSize = SettingsMetrics.minimumWindow
            }
            window.contentMaxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }

        /// A restored frame below the minimum, like the old tabbed window's, grows to at least the opening size.
        private static func grow(_ window: NSWindow) {
            let size = window.contentLayoutRect.size
            let minimum = SettingsMetrics.minimumWindow
            if size.width < minimum.width - 1 || size.height < minimum.height - 1 {
                window.setContentSize(CGSize(
                    width: max(size.width, SettingsMetrics.window.width),
                    height: max(size.height, SettingsMetrics.window.height)))
            }
        }
    }
}

/// The top of a pane, as System Settings starts each one: the pane's icon large, its title, and what it is for.
struct SettingsPaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: pane.tint.opacity(0.35), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: pane.title)
                        .font(.title3.weight(.semibold))
                    Text(verbatim: pane.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }
}

extension SettingsPane {
    /// the pane header's line on what the pane is for
    var summary: String {
        switch self {
        case .general: "How MegaMonitor starts and opens links."
        case .menuBar: "What the menu bar shows, and what its menu lists."
        case .notifications: "Which builds alert you, and what lands in your Inbox."
        case .appearance: "How details, text, code changes and discussions look."
        case .shortcuts: "The keys for the window's commands, and one for opening MegaMonitor from anywhere."
        case .accounts: "Sign in to GitLab and Jenkins. Tokens stay in your keychain."
        case .projects: "The Jenkins jobs and GitLab projects MegaMonitor watches."
        case .team: "Labels, slots and squads, the same for everyone on your team."
        case .pipelines: "How often Jenkins is checked, and when finished builds hide."
        case .workItems: "Which work items show, and in what order."
        case .workspaces: "Your local checkouts, your IDE and your terminal."
        case .claude: "Claude in failed builds, discussions and the daily digest."
        case .advanced: "Settings you rarely need."
        }
    }
}

extension View {
    /// A single pane's size outside the Settings window, as the gallery shows a form: 560 pt wide, starting at an
    /// estimated height until the form has measured itself.
    func settingsPaneFrame(estimate: CGFloat) -> some View {
        modifier(SettingsPaneFrame(estimate: estimate))
    }
}
