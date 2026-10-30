import AppKit
import MenubarCore

/// The default browser through `NSWorkspace` (APP-09). Changing it is the user's decision: macOS asks them to confirm
/// each change, and a refusal comes back as an error.
@MainActor
final class NativeDefaultBrowser: DefaultBrowserSystem {
    /// the link whose handler is the browser
    private static let probe = URL(string: "https://example.com")!

    var thisApp: BrowserApp? {
        Self.browser(at: Bundle.main.bundleURL)
    }

    func defaultBrowser() -> BrowserApp? {
        NSWorkspace.shared.urlForApplication(toOpen: Self.probe).map(Self.browser(at:))
    }

    func app(bundleID: String) -> BrowserApp? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map(Self.browser(at:))
    }

    func exists(_ app: BrowserApp) -> Bool {
        FileManager.default.fileExists(atPath: app.url.path(percentEncoded: false))
    }

    func setDefaultBrowser(_ app: BrowserApp) async throws {
        for scheme in ["http", "https"] {
            try await NSWorkspace.shared.setDefaultApplication(at: app.url, toOpenURLsWithScheme: scheme)
        }
    }

    func open(_ url: URL, with app: BrowserApp) async {
        let configuration = NSWorkspace.OpenConfiguration()
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app.url, configuration: configuration)
        } catch {
            // Never the link itself in the log.
            AppLog.error("couldn't open a link to \(url.host(percentEncoded: false) ?? "no host") in \(app.name): \(error.localizedDescription)")
        }
    }

    private static func browser(at url: URL) -> BrowserApp {
        let bundle = Bundle(url: url)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return BrowserApp(url: url, bundleID: bundle?.bundleIdentifier, name: name)
    }
}
