import Foundation

/// What the app knows about labels besides the filters: when a work item last had each, GitLab's colors, and the filter
/// labels GitLab no longer has (WI-06).
public struct LabelMemory: Codable, Hashable, Sendable {
    /// when a loaded work item last had each label, by title
    public var lastSeen: [String: Date]
    /// GitLab's colors by title, like `#428BCA`, from the work items and the label searches
    public var colors: [String: String]
    /// the filter labels GitLab didn't have when last asked (renamed or removed)
    public var missing: [String]

    public init(lastSeen: [String: Date] = [:], colors: [String: String] = [:], missing: [String] = []) {
        self.lastSeen = lastSeen
        self.colors = colors
        self.missing = missing
    }

    /// how long a label no work item had stays offered
    public static let keptFor: TimeInterval = 30 * 86400

    /// the remembered labels, sorted
    public var known: [String] {
        lastSeen.keys.sorted()
    }

    /// Notes the labels of loaded work items.
    ///
    /// - Their colors are always kept.
    /// - They count as seen only while no must-have label is set: an answer filtered to a label only has its
    ///   co-labels.
    /// - Labels unseen for 30 days are dropped.
    ///
    /// - Parameters:
    ///   - workItems: the loaded work items
    ///   - filters: the filters they were loaded with
    ///   - now: the time of the load
    public mutating func remember(_ workItems: [WorkItem], filters: WorkItemFilters, at now: Date) {
        let labels = workItems.flatMap(\.labels)
        remember(colorsOf: labels)
        if filters.withLabels.isEmpty {
            for label in labels {
                lastSeen[label.title] = now
            }
        }
        lastSeen = lastSeen.filter { now.timeIntervalSince($0.value) < Self.keptFor }
    }

    /// Keeps the colors of labels GitLab sent.
    ///
    /// - Parameter labels: the labels, from work items or a label search
    public mutating func remember(colorsOf labels: [Label]) {
        for label in labels {
            if let color = label.color {
                colors[label.title] = color
            }
        }
    }

    /// Returns the filter labels flagged as gone. A label taken out of the filters loses its flag at once.
    ///
    /// - Parameter filters: the current filters
    /// - Returns: the flagged labels, in the order of the filters
    public func missingFilterLabels(of filters: WorkItemFilters) -> [String] {
        (filters.withLabels + filters.withoutLabels).filter(missing.contains)
    }

    /// Returns the log message of a filter label GitLab no longer has, logged once as a warning with outcome
    /// `warning:MISSING`.
    ///
    /// - Parameter label: the label's title
    /// - Returns: "The filter label X is not in GitLab any more (renamed or removed?)"
    public static func missingMessage(label: String) -> String {
        "The filter label \(label) is not in GitLab any more (renamed or removed?)"
    }
}

extension CacheFile where Value == LabelMemory {
    /// the remembered labels, their colors and the gone filter labels (WI-06)
    public static var labels: CacheFile { CacheFile("labels") }
}

extension CacheFile where Value == MergeRequestList {
    /// my open MRs with my username, which sorts them into their sections at launch (MR-01, OD-01). It replaces
    /// ``mergeRequests``, which holds the MRs without the username.
    public static var mergeRequestList: CacheFile { CacheFile("merge-request-list") }
}

extension CacheFile where Value == WorkItemLists {
    /// the work items of the filters (WI-01)
    public static var workItems: CacheFile { CacheFile("work-items") }
}

extension CacheFile where Value == RelatedMergeRequestsCache {
    /// the related MRs of the work items (WI-05, OD-03)
    public static var relatedMergeRequests: CacheFile { CacheFile("related-merge-requests") }
}

extension Label {
    /// Returns the color of text on a label: black when 0.299 R + 0.587 G + 0.114 B > 0.6, white otherwise (WI-06).
    ///
    /// - Parameter background: the label's color, `#rrggbb`
    /// - Returns: `#000000` or `#FFFFFF`; `nil` when the color isn't `#rrggbb`
    public static func textColor(onBackground background: String) -> String? {
        guard background.count == 7, background.hasPrefix("#"), let rgb = Int(background.dropFirst(), radix: 16) else { return nil }
        let red = Double(rgb >> 16 & 0xFF) / 255
        let green = Double(rgb >> 8 & 0xFF) / 255
        let blue = Double(rgb & 0xFF) / 255
        return 0.299 * red + 0.587 * green + 0.114 * blue > 0.6 ? "#000000" : "#FFFFFF"
    }

    /// Returns a scoped label's scope and value, split at its last `::`, like `uStatus` and `Todo`.
    ///
    /// - Parameter title: the label's title
    /// - Returns: the scope and the value, or `nil` for a label without `::`
    public static func scopeAndValue(of title: String) -> (scope: String, value: String)? {
        guard let range = title.range(of: "::", options: .backwards) else { return nil }
        return (String(title[..<range.lowerBound]), String(title[range.upperBound...]))
    }

    /// The labels of one scope in the label picker, or the labels without one (WI-06).
    public struct Group: Hashable, Sendable, Identifiable {
        /// the scope, like `uStatus`; `nil` for "Other Labels"
        public var scope: String?
        /// the label titles, in the order given
        public var labels: [String]

        public init(scope: String?, labels: [String]) {
            self.scope = scope
            self.labels = labels
        }

        public var id: String { scope ?? "" }

        /// the scope, or "Other Labels"
        public var title: String { scope ?? "Other Labels" }
    }

    /// Groups labels by scope for the picker: the scopes in alphabetical order, then "Other Labels" (WI-06).
    ///
    /// - Parameter titles: the label titles
    /// - Returns: the groups
    public static func groupedByScope(_ titles: [String]) -> [Group] {
        let byScope = Dictionary(grouping: titles) { scopeAndValue(of: $0)?.scope }
        let scopes = byScope.keys.compactMap { $0 }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return scopes.map { Group(scope: $0, labels: byScope[$0] ?? []) }
            + (byScope[nil].map { [Group(scope: nil, labels: $0)] } ?? [])
    }
}
