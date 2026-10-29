import Foundation

/// The id that every stored value of a project is keyed by: its caches folder, its watched and hidden builds.
///
/// It is a folder name, so it holds only ASCII letters, digits, `-`, `_` and `.`, and it never starts with a `.`.
/// v1 has exactly one project, ``ProjectID/main``.
public struct ProjectID: RawRepresentable, Hashable, Comparable, Codable, CodingKeyRepresentable, Sendable,
    CustomStringConvertible
{
    /// the id, safe as a folder name
    public let rawValue: String

    /// Creates an id, or `nil` when the text isn't safe as a folder name.
    ///
    /// - Parameter rawValue: 1 to 64 ASCII letters, digits, `-`, `_` or `.`, not starting with a `.`
    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// the project of v1, the only one until several projects come (plan Phase 13)
    public static let main = ProjectID(rawValue: "main")!

    /// Creates a new, random id, for a project added later.
    ///
    /// - Returns: an id like `p-1f0c…`
    public static func random() -> ProjectID {
        ProjectID(rawValue: "p-" + UUID().uuidString.lowercased())!
    }

    public var description: String { rawValue }

    public static func < (lhs: ProjectID, rhs: ProjectID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// A dictionary keyed by ids encodes as a JSON object, not as an array of keys and values.
    public var codingKey: any CodingKey { AnyKey(stringValue: rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }

    private static func isValid(_ text: String) -> Bool {
        guard (1...64).contains(text.utf8.count), !text.hasPrefix(".") else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar))
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }
}
