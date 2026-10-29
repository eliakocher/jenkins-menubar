import MenubarCore
import SwiftUI

/// The update in the main window's toolbar, group 2 of `docs/design/main-window.md` (APP-05, `update-row.md`).
///
/// It is hidden as a whole item while the app is up to date. Otherwise it offers "Update Ready — Rebuild" with
/// `arrow.down.circle`, also after a failed rebuild (the window's problem rows show the failure); while the rebuild
/// runs it reads "Rebuilding…", disabled, with a spinner in the symbol's place, and "Relaunching…" once the new app is
/// installed.
///
/// The window passes the update store's state and ``rebuild(_:router:)``:
/// ```swift
/// UpdateToolbarItem(state: updates.state) { UpdateToolbarItem.rebuild(updates, router: router) }
/// ```
public struct UpdateToolbarItem: ToolbarContent {
    private let state: UpdateState
    private let rebuild: @MainActor () -> Void

    /// - Parameters:
    ///   - state: `UpdateStore.state`
    ///   - rebuild: rebuilds and relaunches, usually ``rebuild(_:router:)``
    public init(state: UpdateState, rebuild: @escaping @MainActor () -> Void) {
        self.state = state
        self.rebuild = rebuild
    }

    public var body: some ToolbarContent {
        if UpdateRow.shows(state) {
            ToolbarItem {
                UpdateToolbarButton(state: state, rebuild: rebuild)
            }
        }
    }

    /// Rebuilds the app through the store, then hands the new app to the router, which opens it and quits (APP-05). A
    /// failure leaves the app running with the store's error, which the problem rows show.
    ///
    /// - Parameters:
    ///   - updates: the app's update store
    ///   - router: the app's router, whose `onRebuilt` relaunches
    @MainActor
    public static func rebuild(_ updates: UpdateStore, router: WindowRouter) {
        Task {
            if let app = await updates.rebuild() {
                router.onRebuilt?(app)
            }
        }
    }
}

/// The toolbar item's button, for a window that builds its own `ToolbarItem`; it draws nothing sensible while the app
/// is up to date, so show it only while ``UpdateToolbarItem`` would.
public struct UpdateToolbarButton: View {
    private let state: UpdateState
    private let rebuild: @MainActor () -> Void

    /// - Parameters:
    ///   - state: `UpdateStore.state`
    ///   - rebuild: rebuilds and relaunches
    public init(state: UpdateState, rebuild: @escaping @MainActor () -> Void) {
        self.state = state
        self.rebuild = rebuild
    }

    public var body: some View {
        Button(action: rebuild) {
            switch state {
            case .rebuilding:
                Label {
                    Text(UpdateText.rebuilding)
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
            case .installed:
                Label {
                    Text(UpdateText.relaunching)
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
            case .upToDate, .updateReady, .failed:
                Label(UpdateText.offer, systemImage: Marker.update)
            }
        }
        .labelStyle(.titleAndIcon)
        .disabled(!isOffered)
        .help(UpdateText.help)
    }

    private var isOffered: Bool {
        switch state {
        case .updateReady, .failed: true
        case .upToDate, .rebuilding, .installed: false
        }
    }
}
