import Foundation

/// How a work item row's second line shows the labels (WI-04): which ones it leaves out and whether a scoped label
/// shows by its value only. Display only: the filters, the search and the detail keep every label, and a change of
/// it doesn't reload the work items.
public struct WorkItemRowLabels: Codable, Hashable, Sendable {
    /// labels or scope prefixes the rows leave out, matched as a prefix of the label's title, ignoring case: `group:`
    /// hides `group:SquadA` and `group::SquadA`, `affects::` every `affects::…` label
    public var hidden: [String]
    /// whether a scoped label shows as its value, `priority::high` as `high`
    public var showsScopedValueOnly: Bool

    public init(hidden: [String] = [], showsScopedValueOnly: Bool = false) {
        self.hidden = hidden
        self.showsScopedValueOnly = showsScopedValueOnly
    }

    /// whether nothing is hidden or shortened, the default
    public var isDefault: Bool { self == WorkItemRowLabels() }

    // A value encoded before a field existed decodes with that field's default.
    private enum CodingKeys: String, CodingKey {
        case hidden, showsScopedValueOnly
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hidden = try container.decodeIfPresent([String].self, forKey: .hidden) ?? []
        showsScopedValueOnly = try container.decodeIfPresent(Bool.self, forKey: .showsScopedValueOnly) ?? false
    }

    /// Returns the text a row shows for a label.
    ///
    /// - Parameter title: the label's whole title, like `priority::high`
    /// - Returns: `nil` when the row hides it, else its title, or only the value after the last `::` for a scoped
    ///   label when ``showsScopedValueOnly`` is on
    public func text(of title: String) -> String? {
        for prefix in hidden {
            let prefix = prefix.trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty, title.lowercased().hasPrefix(prefix.lowercased()) {
                return nil
            }
        }
        if showsScopedValueOnly, let range = title.range(of: "::", options: .backwards), range.upperBound < title.endIndex {
            return String(title[range.upperBound...])
        }
        return title
    }

    /// Splits typed text into the entries of ``hidden``.
    ///
    /// - Parameter text: entries separated by commas, like `group:, affects::`
    /// - Returns: the trimmed entries without the empty ones and the repeats, in the order typed
    public static func entries(from text: String) -> [String] {
        var seen: Set<String> = []
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
