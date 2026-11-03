import Foundation

/// One released version's section of `CHANGELOG.md`: what the "What's New" view shows.
public struct ChangelogSection: Hashable, Sendable, Identifiable {
    /// the version as the heading has it, like "1.0.4"
    public var version: String
    /// the release date as written, like "2026-11-03"; nil when the heading has none
    public var date: String?
    /// the section's Markdown below its heading, trimmed: the "### Added" groups and their lists
    public var body: String

    public init(version: String, date: String?, body: String) {
        self.version = version
        self.date = date
        self.body = body
    }

    public var id: String { version }
}

/// Reads `CHANGELOG.md` (Keep a Changelog) for the "What's New" view: its `## [x.y.z] - date` sections.
public enum Changelog {
    /// the resource's name in the app bundle, which `build.sh` copies in; a missing file reads as an empty changelog
    public static let resourceName = "CHANGELOG"

    /// Reads the changelog the app bundle carries.
    ///
    /// - Parameter bundle: the bundle with the resource; the app's main bundle by default
    /// - Returns: the released sections, newest first; empty when the file isn't there (tests, the gallery, a bare debug
    ///   binary)
    public static func bundled(in bundle: Bundle = .main) -> [ChangelogSection] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return []
        }
        return parse(text)
    }

    /// Parses the changelog's text into its released sections.
    ///
    /// `## [Unreleased]` and anything that isn't a `## [x.y.z]` heading are left out, and so are the link reference lines
    /// (`[1.0.4]: https://…`) at the end. The result is sorted by version, the newest first, whatever the file's order.
    ///
    /// - Parameter text: the file's text
    /// - Returns: the sections, newest first
    public static func parse(_ text: String) -> [ChangelogSection] {
        var sections: [ChangelogSection] = []
        var current: (version: String, date: String?, lines: [Substring])?
        func finish() {
            guard let found = current else {
                return
            }
            let lines = found.lines.filter { $0.wholeMatch(of: /\[[^\]]+\]:\s+\S.*/) == nil }
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append(ChangelogSection(version: found.version, date: found.date, body: body))
            current = nil
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                finish()
                if let match = line.wholeMatch(of: /##\s+\[([^\]]+)\](?:\s+-\s+(.+?))?\s*/), VersionNumber(String(match.1)) != nil {
                    current = (String(match.1), match.2.map(String.init), [])
                }
            } else if current != nil {
                current?.lines.append(line)
            }
        }
        finish()
        return sections.sorted { VersionNumber($0.version)! > VersionNumber($1.version)! }
    }

    /// Returns the sections of a range of versions.
    ///
    /// - Parameters:
    ///   - sections: the changelog's sections
    ///   - from: the version the range starts after; nil for no lower end
    ///   - to: the version the range ends at, included; nil for no upper end
    /// - Returns: the sections in the range, newest first
    public static func sections(_ sections: [ChangelogSection], from: String?, to: String?) -> [ChangelogSection] {
        let lower = from.flatMap(VersionNumber.init)
        let upper = to.flatMap(VersionNumber.init)
        return sections.filter { section in
            guard let number = VersionNumber(section.version) else {
                return false
            }
            return (lower.map { number > $0 } ?? true) && (upper.map { number <= $0 } ?? true)
        }
    }
}

/// A dotted version, "1.0.4", compared number by number, so "1.0.10" is after "1.0.9". A part's trailing text ("4-beta")
/// is ignored; a version without a leading number is no version.
public struct VersionNumber: Hashable, Comparable, Sendable {
    let parts: [Int]

    public init?(_ text: String) {
        var parts: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard let number = Int(part.prefix { $0.isNumber }) else {
                return nil
            }
            parts.append(number)
        }
        guard !parts.isEmpty else {
            return nil
        }
        self.parts = parts
    }

    public static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    public static func == (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}
