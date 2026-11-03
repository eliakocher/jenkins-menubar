import Foundation

/// One line of the About window's credits: the role and who or what had it.
public struct CreditLine: Sendable, Equatable {
    /// the role, right-aligned beside the gap; empty on a line that continues the role above it
    public let role: String
    /// the name, left-aligned beside the gap
    public let name: String

    public init(_ role: String, _ name: String) {
        self.role = role
        self.name = name
    }
}

/// What the About window says besides the app's icon, name and version (EGG-21).
public enum AboutCredits {
    /// the copyright line
    public static let copyright = "© 2026 Elia Kocher"

    /// The author's serious credit, which stays with the easter eggs off.
    public static let author = CreditLine("Created by", "Elia Kocher")

    /// the line under the roll, with the eggs on
    public static let closingLine = "No builds were harmed in the making of this app. Several were retried."

    /// The movie-style roll, in groups the window separates with a gap.
    ///
    /// - Parameter eggs: whether the easter eggs are on
    /// - Returns: the groups of lines; with the eggs off only the author's serious credit
    public static func groups(eggs: Bool) -> [[CreditLine]] {
        guard eggs else {
            return [[author]]
        }
        return [
            [CreditLine("Directed by", "the butler")],
            [
                CreditLine("Written, built and blamed", "Elia Kocher"),
                CreditLine("Producer of merge conflicts", "Elia Kocher"),
                CreditLine("Chief coffee officer", "Elia Kocher"),
                CreditLine("Prod deploy stunt double", "Elia Kocher"),
                CreditLine("Rerun-button technician", "Elia Kocher"),
            ],
            [
                CreditLine("Starring", "Flaky tests as themselves"),
                CreditLine("", "The VPN as the VPN"),
                CreditLine("", "\u{201C}Works on my machine\u{201D} as the machine"),
            ],
            [
                CreditLine("Catering", "the coffee machine"),
                CreditLine("Spellcheck", "coming in the next demo"),
            ],
            [CreditLine("Special thanks", "Elia Kocher's patience")],
        ]
    }
}

extension AboutCredits {
    /// The version line under the app's name.
    ///
    /// - Parameter info: the bundle's Info.plist entries
    /// - Returns: for example "Version 1.0.1 (2)"; just the short version when there is no build number; empty when
    ///   the bundle says nothing (a bare debug binary)
    public static func versionLine(info: [String: Any]?) -> String {
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case (let short?, let build?) where build != short: return "Version \(short) (\(build))"
        case (let short?, _): return "Version \(short)"
        case (nil, let build?): return "Build \(build)"
        default: return ""
        }
    }
}
