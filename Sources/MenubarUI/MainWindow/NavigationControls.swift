import AppKit
import MenubarCore
import SwiftUI

/// What the toolbar's Back and Forward buttons show and do (WIN-08), as plain values and closures so the shell stays
/// free of the router. The lists of places are closures: they read the stores, and only a menu that opens asks for them.
struct NavigationControls {
    /// one place in a menu: its symbol and title
    struct Entry: Identifiable {
        /// the place's position in the menu; the same place can be in the history twice
        var id: Int
        var location: NavigationLocation
        var title: String
        var systemImage: String
    }

    var canGoBack: Bool
    var canGoForward: Bool
    /// the places Back reaches that still exist, the nearest first
    var backEntries: @MainActor () -> [Entry]
    var forwardEntries: @MainActor () -> [Entry]
    var goBack: @MainActor () -> Void
    var goForward: @MainActor () -> Void
    var jump: @MainActor (NavigationLocation) -> Void
}

/// The Back ‹ and Forward › buttons at the leading side of the window's toolbar (WIN-08). A click goes one place; a long
/// press or a right-click lists the places, newest first for Back, to jump to.
struct NavigationButtons: ToolbarContent {
    let controls: NavigationControls

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            button("Back", systemImage: "chevron.left", isEnabled: controls.canGoBack, entries: controls.backEntries) {
                controls.goBack()
            }
            .help("Back (⌘[). Press and hold for the places before.")
            button(
                "Forward", systemImage: "chevron.right", isEnabled: controls.canGoForward, entries: controls.forwardEntries
            ) {
                controls.goForward()
            }
            .help("Forward (⌘]). Press and hold for the places after.")
        }
    }

    private func button(
        _ title: String, systemImage: String, isEnabled: Bool,
        entries: @escaping @MainActor () -> [NavigationControls.Entry], action: @escaping @MainActor () -> Void
    ) -> some View {
        Menu {
            NavigationEntryMenu(entries: entries, jump: controls.jump)
        } label: {
            Label(title, systemImage: systemImage)
        } primaryAction: {
            action()
        }
        .menuIndicator(.hidden)
        .contextMenu {
            NavigationEntryMenu(entries: entries, jump: controls.jump)
        }
        .disabled(!isEnabled)
    }
}

/// The places of a Back or Forward menu, each with its symbol and title.
private struct NavigationEntryMenu: View {
    let entries: @MainActor () -> [NavigationControls.Entry]
    let jump: @MainActor (NavigationLocation) -> Void

    var body: some View {
        ForEach(entries()) { entry in
            Button {
                jump(entry.location)
            } label: {
                Label(entry.title, systemImage: entry.systemImage)
            }
        }
    }
}
