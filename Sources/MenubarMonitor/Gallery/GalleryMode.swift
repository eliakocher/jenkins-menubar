#if DEBUG
import AppKit
import MenubarCore
import MenubarUI
import SwiftUI

/// `MegaMonitor --gallery`: one window per gallery entry, drawn from fixtures, for the design reviews'
/// screenshots. Debug builds only.
///
/// The appearance is set on each window, and the SwiftUI environment values that can be set are set to match; nothing
/// changes in System Settings. Reduce Transparency and Reduce Motion reach the SwiftUI views only, not the materials
/// AppKit draws. Without `--activate` the gallery stays in the background, so it doesn't take the keyboard focus; its
/// SwiftUI views still draw as in the key window, but what AppKit draws, such as the window frame and progress bars,
/// draws as inactive (grey).
///
/// Once the windows are on screen, it writes the manifest (by default `build/gallery/manifest.json` in the checkout),
/// which maps each entry id to its window number for `screencapture -l`, and prints its path.
@MainActor
enum GalleryMode {
    static let usage = """
        usage: MegaMonitor --gallery [--only <screen or id>]... [--appearance light|dark|light-hc|dark-hc]
                                         [--type-size <\(DynamicTypeSize.allCases.map { "\($0)" }.joined(separator: "|"))>]
                                         [--reduce-transparency] [--reduce-motion] [--activate] [--manifest <path>]
        """

    static func run(arguments: [String]) -> Never {
        let options: GalleryOptions
        do {
            options = try GalleryOptions(arguments: arguments)
        } catch {
            FileHandle.standardError.write(Data("\(error.message)\n\(usage)\n".utf8))
            exit(2)
        }
        let delegate = GalleryDelegate(options: options)
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
        exit(0)
    }
}

struct GalleryOptions {
    enum Appearance: String, CaseIterable {
        case light
        case dark
        case lightHighContrast = "light-hc"
        case darkHighContrast = "dark-hc"

        var name: NSAppearance.Name {
            switch self {
            case .light: .aqua
            case .dark: .darkAqua
            case .lightHighContrast: .accessibilityHighContrastAqua
            case .darkHighContrast: .accessibilityHighContrastDarkAqua
            }
        }

        var colorScheme: ColorScheme {
            self == .light || self == .lightHighContrast ? .light : .dark
        }

        var contrast: ColorSchemeContrast {
            self == .light || self == .dark ? .standard : .increased
        }
    }

    struct UsageError: Error {
        let message: String
    }

    var only: Set<String> = []
    var appearance = Appearance.light
    var typeSize: DynamicTypeSize?
    var reduceTransparency = false
    var reduceMotion = false
    var activate = false
    var manifest: URL?

    init(arguments: [String]) throws(UsageError) {
        var arguments = arguments[...]
        func value(of option: String) throws(UsageError) -> String {
            guard let value = arguments.popFirst() else {
                throw UsageError(message: "\(option) needs a value")
            }
            return value
        }
        while let argument = arguments.popFirst() {
            switch argument {
            case "--gallery":
                break
            case "--only":
                only.insert(try value(of: argument))
            case "--appearance":
                let name = try value(of: argument)
                guard let appearance = Appearance(rawValue: name) else {
                    throw UsageError(message: "unknown appearance \(name)")
                }
                self.appearance = appearance
            case "--type-size":
                let name = try value(of: argument)
                guard let size = DynamicTypeSize.allCases.first(where: { "\($0)" == name }) else {
                    throw UsageError(message: "unknown type size \(name)")
                }
                typeSize = size
            case "--reduce-transparency":
                reduceTransparency = true
            case "--reduce-motion":
                reduceMotion = true
            case "--activate":
                activate = true
            case "--manifest":
                manifest = URL(filePath: try value(of: argument))
            default:
                throw UsageError(message: "unknown option \(argument)")
            }
        }
    }

    func includes(_ entry: GalleryEntry) -> Bool {
        only.isEmpty || only.contains(entry.id) || only.contains(entry.screen)
    }
}

@MainActor
final class GalleryDelegate: NSObject, NSApplicationDelegate {
    private let options: GalleryOptions
    private var windows: [(entry: GalleryEntry, window: NSWindow)] = []

    init(options: GalleryOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let entries = GalleryCatalog.entries.filter(options.includes)
        guard !entries.isEmpty else {
            FileHandle.standardError.write(Data("no gallery entry matches \(options.only.sorted())\n".utf8))
            exit(1)
        }
        let fixtures = Fixtures()
        var topLeft = NSPoint.zero
        for entry in entries {
            var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            if Self.mainWindowScreens.contains(entry.screen) {
                // As the real main window: the split view's columns reach under the toolbar, which splits over them,
                // and the sidebar floats (MAIN-WINDOW-04).
                styleMask.insert(.fullSizeContentView)
            }
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: entry.size),
                styleMask: styleMask,
                backing: .buffered,
                defer: false
            )
            window.title = entry.id
            window.isReleasedWhenClosed = false
            // Without the open animation, a screenshot never catches a window still growing to its size.
            window.animationBehavior = .none
            window.appearance = NSAppearance(named: options.appearance.name)
            let hostingView = NSHostingView(rootView: entry.makeView(fixtures).modifier(GalleryEnvironment(options: options)))
            hostingView.sceneBridgingOptions = .all
            window.contentView = hostingView
            window.setContentSize(Self.fittingSize(of: hostingView, entry: entry))
            topLeft = window.cascadeTopLeft(from: topLeft)
            if options.activate {
                window.makeKeyAndOrderFront(nil)
            } else {
                // Behind the other apps' windows, so the gallery stays out of the way; `screencapture -l` takes a
                // window's own image even where others cover it.
                window.orderBack(nil)
            }
            windows.append((entry, window))
        }
        if options.activate {
            NSApp.activate()
        }
        Task {
            // Views that measure themselves, like the panel's scroll view, settle in the first layout passes, so the
            // windows fit them again until no size changes, for at most 5 s. Then the window server gets time to draw
            // before anything takes a screenshot: right after a previous gallery quit, it still scales new windows in
            // for a while, and 0.5 s caught them shrunk.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                if !fitWindows() {
                    break
                }
            }
            try? await Task.sleep(for: .seconds(2))
            writeManifest()
        }
    }

    /// Fits every window to its content once more.
    ///
    /// - Returns: whether a window changed its size
    private func fitWindows() -> Bool {
        var changed = false
        for (entry, window) in windows {
            guard let hostingView = window.contentView else {
                continue
            }
            let size = Self.fittingSize(of: hostingView, entry: entry)
            // The content view's own size, which `setContentSize` sets; with a full-size content view the layout rect
            // leaves out the toolbar and would never match.
            if hostingView.frame.size != size {
                window.setContentSize(size)
                changed = true
            }
        }
        return changed
    }

    /// The size the entry's view asks for, so a screenshot shows what the real panel, alert or sheet shows: a fixed
    /// width and the height of the content. The entry's size stands in for a view that asks for nothing.
    private static func fittingSize(of view: NSView, entry: GalleryEntry) -> NSSize {
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        return NSSize(
            width: fitting.width > 1 ? fitting.width : entry.size.width,
            height: fitting.height > 1 ? fitting.height : entry.size.height)
    }

    /// The screens whose entries show the main window, with its sidebar and toolbar.
    private static let mainWindowScreens: Set<String> = ["main-window", "pipelines", "merge-requests", "work-items", "activity"]

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Writes the manifest: a JSON object that maps each entry id to its window number, such as
    /// `{"placeholder.environment": 4711}`. The designer agent and `scripts/gallery-shots.sh` rely on exactly this shape.
    private func writeManifest() {
        var manifest: [String: Int] = [:]
        for (entry, window) in windows {
            manifest[entry.id] = window.windowNumber
        }
        let url = options.manifest ?? Self.defaultManifestURL
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(manifest).write(to: url, options: .atomic)
            print(url.path)
        } catch {
            FileHandle.standardError.write(Data("cannot write \(url.path): \(error)\n".utf8))
            exit(1)
        }
    }

    /// `build/gallery/manifest.json` in the checkout the app was built from, or in the current folder outside a bundle.
    private static var defaultManifestURL: URL {
        let root = Bundle.main.object(forInfoDictionaryKey: AppIdentity.sourceRootKey) as? String
        let base = root.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? URL.currentDirectory()
        return base.appending(path: "build/gallery/manifest.json")
    }
}

/// The SwiftUI side of the gallery's options. Values without an option are set too, so screenshots don't depend on the
/// Mac's own settings.
private struct GalleryEnvironment: ViewModifier {
    let options: GalleryOptions

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, options.appearance.colorScheme)
            .environment(\._colorSchemeContrast, options.appearance.contrast)
            .environment(\.dynamicTypeSize, options.typeSize ?? .large)
            .environment(\._accessibilityReduceTransparency, options.reduceTransparency)
            .environment(\._accessibilityReduceMotion, options.reduceMotion)
            .environment(\.controlActiveState, .key)
    }
}
#endif
