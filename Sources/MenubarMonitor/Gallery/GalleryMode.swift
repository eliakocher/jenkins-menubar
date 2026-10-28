#if DEBUG
import AppKit
import MenubarCore
import MenubarUI
import SwiftUI

/// `menubar-monitor --gallery`: one window per gallery entry, drawn from fixtures, for the design reviews'
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
        usage: menubar-monitor --gallery [--only <screen or id>]... [--appearance light|dark|light-hc|dark-hc]
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
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: entry.size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = entry.id
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: options.appearance.name)
            let hostingView = NSHostingView(rootView: entry.makeView(fixtures).modifier(GalleryEnvironment(options: options)))
            hostingView.sceneBridgingOptions = .all
            window.contentView = hostingView
            window.setContentSize(entry.size)
            topLeft = window.cascadeTopLeft(from: topLeft)
            if options.activate {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
            windows.append((entry, window))
        }
        if options.activate {
            NSApp.activate()
        }
        Task {
            // Lets SwiftUI lay out and the window server draw before anything takes a screenshot.
            try? await Task.sleep(for: .seconds(1))
            writeManifest()
        }
    }

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
