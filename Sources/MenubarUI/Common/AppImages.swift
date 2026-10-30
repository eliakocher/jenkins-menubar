import AppKit
import MenubarCore
import SwiftUI

/// The app's own images from the bundle's resources, each loaded as an instance of its own: `NSImage(named:)` hands
/// out one shared instance, and a change of its size would reach every user.
@MainActor
enum AppImages {
    /// The butler, `icons/menubar.png`, as a template that macOS tints for the menu bar. The file is 38 × 36 px at
    /// 144 dpi; the size is set anyway, so it never depends on how the file is read (`docs/decisions.md`, Task 4.2).
    static let butler: NSImage = {
        let image = load("menubar") ?? NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil) ?? NSImage()
        image.size = NSSize(width: 19, height: 18)
        image.isTemplate = true
        return image
    }()

    /// Returns the butler of the status icon, with a hat or in a bow frame (the easter eggs, `docs/easter-eggs.md`).
    ///
    /// The files are `icons/menubar-party.png`, `menubar-santa.png`, `menubar-bow-1.png` (half bow) and
    /// `menubar-bow-2.png` (full bow), templates like `menubar.png`. A file that isn't in the bundle changes nothing:
    /// the plain butler shows.
    ///
    /// - Parameters:
    ///   - hat: the hat, or `nil`
    ///   - bow: the bow frame, or `nil` for the butler standing
    static func butler(hat: ButlerHat?, bow: BowFrame?) -> NSImage {
        let name: String? = switch (bow, hat) {
        case (.half?, _): "menubar-bow-1"
        case (.full?, _): "menubar-bow-2"
        case (_, .party?): "menubar-party"
        case (_, .santa?): "menubar-santa"
        default: nil
        }
        guard let name, let cached = variants[name] ?? loadTemplate(name) else {
            return butler
        }
        return cached
    }

    /// the template variants loaded so far; a file that is missing is looked for again each time, which costs nothing
    private static var variants: [String: NSImage] = [:]

    /// Loads a template butler at the menu bar's height, keeping the file's proportions: the plain butler's file is 38 × 36
    /// px, shown 19 × 18 pt.
    private static func loadTemplate(_ name: String) -> NSImage? {
        guard let image = load(name), let rep = image.representations.first, rep.pixelsHigh > 0 else {
            return nil
        }
        image.size = NSSize(width: 18 * CGFloat(rep.pixelsWide) / CGFloat(rep.pixelsHigh), height: 18)
        image.isTemplate = true
        variants[name] = image
        return image
    }

    /// The happy butler of a successful build's alert, `icons/happy.png`.
    static let happy: NSImage = load("happy") ?? symbol("face.smiling")

    /// The sad butler of every other alert, `icons/sad.png`.
    static let sad: NSImage = load("sad") ?? symbol("cloud.rain")

    /// The GitLab tanuki, `icons/gitlab.png`, in full color, for the menu pane's summary rows. The file is 32 px; the size
    /// is set to the row's 14 pt so it stays sharp on a Retina screen.
    static let gitLab: NSImage = {
        let image = load("gitlab") ?? symbol("shippingbox")
        image.size = NSSize(width: 14, height: 14)
        image.isTemplate = false
        return image
    }()

    /// Returns the image of an alert (ALERT-02), with the hat the alert's butler wears: `icons/happy-party.png`,
    /// `happy-santa.png` or `sad-santa.png`. A file that isn't in the bundle changes nothing: the plain butler shows.
    static func alert(_ icon: AlertContent.Icon, hat: ButlerHat? = nil) -> NSImage {
        if let hat, let image = hatted("\(icon.rawValue)-\(hat == .party ? "party" : "santa")") {
            return image
        }
        return icon == .happy ? happy : sad
    }

    private static var hattedImages: [String: NSImage] = [:]

    private static func hatted(_ name: String) -> NSImage? {
        if let image = hattedImages[name] {
            return image
        }
        guard let image = load(name) else {
            return nil
        }
        hattedImages[name] = image
        return image
    }

    /// Outside a bundle, as in the tests, the resources aren't there.
    private static func load(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }

    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }
}

extension MergeRequestStatus.Color {
    /// GitLab's color for the light and the dark appearance, picked by the view's appearance (MR-02). With Increase
    /// Contrast, the light color is darker and the dark one lighter, since GitLab's orange stays below 3:1 on the
    /// menu's light background (review PANEL-05).
    var swiftUI: Color {
        let light = NSColor(hex: self.light)
        let dark = NSColor(hex: self.dark)
        let lightHighContrast = light.blended(withFraction: 0.35, of: .black) ?? light
        let darkHighContrast = dark.blended(withFraction: 0.35, of: .white) ?? dark
        return Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: dark
            case .accessibilityHighContrastAqua: lightHighContrast
            case .accessibilityHighContrastDarkAqua: darkHighContrast
            default: light
            }
        })
    }
}

extension NSColor {
    /// A color from hex text like `#108548`; gray for text that isn't one.
    convenience init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self.init(white: 0.5, alpha: 1)
            return
        }
        self.init(
            srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
