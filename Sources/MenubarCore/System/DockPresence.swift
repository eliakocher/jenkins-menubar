import Foundation

/// The app's windows that are open, which decide whether it shows a Dock icon and is in ⌘-Tab (APP-01).
///
/// The main window, Settings and the welcome flow report themselves from their content's `onAppear` and
/// `onDisappear`. The menubar panel and the alert window never do, so they don't count. Counting windows by name, not
/// by events, keeps a window that reports twice from keeping the Dock icon after it closed.
public struct DockPresence: Hashable, Sendable {
    /// the names of the windows that are open, like `main` and `settings`
    public private(set) var openWindows: Set<String> = []

    public init() {}

    /// whether a window is open, so the app shows a Dock icon (the regular activation policy)
    public var showsDockIcon: Bool {
        !openWindows.isEmpty
    }

    /// Notes that a window appeared.
    ///
    /// - Parameter window: the window's name
    public mutating func opened(_ window: String) {
        openWindows.insert(window)
    }

    /// Notes that a window disappeared.
    ///
    /// - Parameter window: the window's name
    public mutating func closed(_ window: String) {
        openWindows.remove(window)
    }
}
