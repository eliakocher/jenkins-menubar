#if DEBUG
import SwiftUI

/// One screen in one state, as `menubar-monitor --gallery` shows it: the design reviews screenshot every entry.
public struct GalleryEntry: Identifiable, Sendable {
    /// the screen's slug, as in `docs/design/<screen>.md`
    public let screen: String
    /// the state's slug, such as `loading` or `long-titles`
    public let state: String
    /// the content size of the entry's window, in points
    public let size: CGSize
    private let content: @MainActor @Sendable (Fixtures) -> AnyView

    public init<Content: View>(
        screen: String,
        state: String,
        size: CGSize,
        @ViewBuilder content: @escaping @MainActor @Sendable (Fixtures) -> Content
    ) {
        self.screen = screen
        self.state = state
        self.size = size
        self.content = { AnyView(content($0)) }
    }

    /// `<screen>.<state>`, which names the entry's screenshots too.
    public var id: String { "\(screen).\(state)" }

    @MainActor
    public func makeView(_ fixtures: Fixtures) -> AnyView {
        content(fixtures)
    }
}

/// Every gallery entry. Each UI milestone adds an entry for every state in its screen's design spec.
public enum GalleryCatalog {
    @MainActor
    public static let entries: [GalleryEntry] = [
        GalleryEntry(screen: "placeholder", state: "environment", size: CGSize(width: 420, height: 360)) { _ in
            GalleryPlaceholderView()
        },
    ] + statusIconEntries + menuPaneEntries + panelEntries + alertEntries + watchSheetEntries
        + welcomeEntries
        + mainWindowEntries + pipelinesEntries
        + mergeRequestsEntries
        + mergeRequestDetailsEntries
        + workItemsEntries
        + activityEntries
        + workspacesEntries
        + settingsEntries + updateRowEntries
}
#endif
