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
        if let bow, bow.isHop {
            return hop(bow, hat: hat)
        }
        return standing(hat: hat, bow: bow)
    }

    private static func standing(hat: ButlerHat?, bow: BowFrame?) -> NSImage {
        let name: String? = switch (bow, hat) {
        case (.half?, _): "menubar-bow-1"
        case (.full?, _): "menubar-bow-2"
        // New Year's Eve and the days after wear the party hat in the menu bar too: no variant of its own.
        case (_, .party?), (_, .newYear?): "menubar-party"
        case (_, .santa?): "menubar-santa"
        default: nil
        }
        guard let name, let cached = variants[name] ?? loadTemplate(name) else {
            return butler
        }
        return cached
    }

    /// how far the hop lifts and drops the butler, in points; the hop's images are this much taller than 18 pt each side
    static let hopHeight: CGFloat = 2

    /// Returns a frame of the hop: `icons/menubar-wink.png` when the file is there, else the standing butler drawn
    /// ``hopHeight`` points higher or lower in an image that is 2 × ``hopHeight`` points taller, so he stays in place at rest
    /// (the menu bar centers an image) and the hop never clips.
    private static func hop(_ frame: BowFrame, hat: ButlerHat?) -> NSImage {
        if let wink = variants["menubar-wink"] ?? loadTemplate("menubar-wink") {
            return wink
        }
        let base = standing(hat: hat, bow: nil)
        let key = "hop-\(frame == .hopUp ? "up" : "down")-\(hat?.rawValue ?? "none")"
        if let cached = variants[key] {
            return cached
        }
        let size = NSSize(width: base.size.width, height: base.size.height + 2 * hopHeight)
        let lift = frame == .hopUp ? 2 * hopHeight : 0
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(x: 0, y: lift, width: base.size.width, height: base.size.height))
            return true
        }
        image.isTemplate = true
        variants[key] = image
        return image
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

    /// The butler sipping a coffee, `icons/coffee.png` (512 px, transparent), for the coffee break's panel and Inbox rows.
    /// Optional art like the hats: without the file it is `nil` and the ☕ and the cup symbol stay.
    static let coffee: NSImage? = load("coffee")

    /// The GitLab tanuki, `icons/gitlab.png`, in full color, for the menu pane's summary rows. The file is 32 px; the size
    /// is set to the row's 14 pt so it stays sharp on a Retina screen.
    static let gitLab: NSImage = {
        let image = load("gitlab") ?? symbol("shippingbox")
        image.size = NSSize(width: 14, height: 14)
        image.isTemplate = false
        return image
    }()

    /// Returns the image of an alert (ALERT-02), with the hat the alert's butler wears. The art files are
    /// `icons/<happy|sad>-<name>.png` (see ``alertArtNames(_:hat:)`` for the names).
    /// A file that isn't in the bundle changes nothing: the plain butler shows.
    static func alert(_ icon: AlertContent.Icon, hat: ButlerHat? = nil) -> NSImage {
        if let hat, let image = hattedArt(icon, hat: hat) {
            return image
        }
        return icon == .happy ? happy : sad
    }

    /// Returns the file names (without `.png`) of an alert's butler wearing a hat, the first that exists wins: the user's
    /// own art first (`happy-witch`, `sad-witch`, `happy-newyear`, `sad-newyear`), then the older one (`halloween` for the
    /// witch, `party` for New Year's, which wears the party hat; `sad-party` doesn't exist). `santa`, `carnival`, `easter`
    /// and `party` have one name.
    nonisolated static func alertArtNames(_ icon: AlertContent.Icon, hat: ButlerHat) -> [String] {
        let names: [String] = switch hat {
        case .party: ["party"]
        case .newYear: ["newyear", "party"]
        case .santa: ["santa"]
        case .witch: ["witch", "halloween"]
        case .carnival: ["carnival"]
        case .easter: ["easter"]
        }
        return names.map { "\(icon.rawValue)-\($0)" }
    }

    /// Returns the name (without `.png`) of the side peek's art that has a hat on, or `nil` for a hat that has none: the user's
    /// `peek-side-party`, `peek-side-santa` and `peek-side-witch` (New Year's shares the party hat's).
    nonisolated static func peekHatArtName(_ hat: ButlerHat) -> String? {
        switch hat {
        case .party, .newYear: "peek-side-party"
        case .santa: "peek-side-santa"
        case .witch: "peek-side-witch"
        case .carnival, .easter: nil
        }
    }

    private static func hattedArt(_ icon: AlertContent.Icon, hat: ButlerHat) -> NSImage? {
        for name in alertArtNames(icon, hat: hat) {
            if let image = hatted(name) {
                return image
            }
        }
        return nil
    }

    /// Returns whether a butler wearing a hat has no art and gets the drawn hat over the plain butler instead: the
    /// witch's hat and the New Year's hat, when their files are missing. The sad New Year's butler stays plain.
    static func drawsFallbackHat(_ icon: AlertContent.Icon, hat: ButlerHat?) -> Bool {
        guard let hat, hat == .witch || hat == .newYear, !(hat == .newYear && icon == .sad) else {
            return false
        }
        return hattedArt(icon, hat: hat) == nil
    }

    /// The butler of the Inbox's empty state, `icons/inbox-zero.png`; `nil` without the file, and the happy butler with the day's
    /// hat stays.
    static var inboxZero: NSImage? { hatted("inbox-zero") }

    /// The size to show an alert's butler at, in a box of `box` points. The plain art is square and fills the box. The
    /// seasonal art is taller than square, because the hat sits on top: it keeps the plain butler's scale (times
    /// ``seasonalScale``), so his face and body read as big as the plain butler's, and the hat rises above the box.
    static func alertSize(of image: NSImage, box: CGFloat) -> CGSize {
        guard let rep = image.representations.first, rep.pixelsHigh > 0 else {
            return CGSize(width: box, height: box)
        }
        let (width, height) = (CGFloat(rep.pixelsWide), CGFloat(rep.pixelsHigh))
        if abs(width / height - 1) < 0.15 {
            return CGSize(width: box, height: box)
        }
        let scale = box / plainButlerPixels * seasonalScale
        return CGSize(width: width * scale, height: height * scale)
    }

    /// the plain butler's art is 238 px square
    private static let plainButlerPixels: CGFloat = 238
    /// the tall art's scale against the plain butler's, so that the faces match
    static let seasonalScale: CGFloat = 0.72

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
        var url = Bundle.main.url(forResource: name, withExtension: "png")
        #if DEBUG
        // Outside a bundle, as in the renders, the repo's own icons stand in.
        if url == nil {
            let file = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "icons/\(name).png")
            url = FileManager.default.fileExists(atPath: file.path) ? file : nil
        }
        #endif
        return url.flatMap(NSImage.init(contentsOf:))
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
