import AppKit
import MenubarCore

/// Settings → Appearance, applied to the whole app: one `NSApp.appearance` that every window and panel without an
/// appearance of its own inherits (the main window, Settings, About, the console log, the alert and event panels, the
/// menu bar pane).
///
/// The status item is the exception without any code: the system gives its button the menu bar's appearance
/// (`NSAppearanceNameVibrantDark` or `VibrantLight`) on the window itself, which `NSApp.appearance` doesn't override
/// (probed with a scratch app on 2026-11-03), so ``StatusLabel``'s `colorScheme` keeps following the menu bar.
@MainActor
public enum AppAppearance {
    /// The appearance to give the app.
    ///
    /// - Parameter choice: the preference
    /// - Returns: the Aqua appearance for light, the dark one for dark, and `nil` for automatic, which follows macOS
    public static func nsAppearance(for choice: Preferences.Appearance) -> NSAppearance? {
        switch choice {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Sets the app's appearance; the views redraw in it at once.
    ///
    /// - Parameter choice: the preference
    public static func apply(_ choice: Preferences.Appearance) {
        let appearance = nsAppearance(for: choice)
        guard NSApplication.shared.appearance?.name != appearance?.name else { return }
        NSApplication.shared.appearance = appearance
    }
}
