import Foundation

/// The order of the main window's sidebar sections, which the user can change in Settings → Appearance or by dragging
/// the rows (WIN-01). It is kept as one string in the preferences, the sections' link names joined by commas, and an
/// empty string is the default order, ``AppRoute/Section/allCases``.
///
/// A saved order survives updates: a name that isn't a section any more is dropped, and a section it doesn't list yet
/// takes its default place, right after the section that comes before it in the default order. Hidden sections (Digest
/// without Claude) keep their place in the order; the sidebar only skips them.
public enum SectionOrder {
    /// the preferences key, in the personal settings backup
    public static let key = "mainWindow.sectionOrder"

    /// Returns the sections in the saved order.
    ///
    /// - Parameters:
    ///   - stored: the preference's value; empty is the default order
    ///   - sections: every section, in the default order
    /// - Returns: every section once: the saved ones in their order, unknown names and repeats dropped, the sections the
    ///   saved order doesn't know after their default predecessor
    public static func merged(stored: String, sections: [AppRoute.Section] = AppRoute.Section.allCases) -> [AppRoute.Section] {
        var result: [AppRoute.Section] = []
        for name in stored.split(separator: ",") {
            if let section = AppRoute.Section(rawValue: name.trimmingCharacters(in: .whitespaces)),
                sections.contains(section), !result.contains(section)
            {
                result.append(section)
            }
        }
        for (index, section) in sections.enumerated() where !result.contains(section) {
            var position = 0
            for earlier in sections[..<index].reversed() {
                if let found = result.firstIndex(of: earlier) {
                    position = found + 1
                    break
                }
            }
            result.insert(section, at: position)
        }
        return result
    }

    /// Returns the value to keep for an order: empty for the default order, so a later new section lands in its place
    /// without anyone having reordered anything.
    ///
    /// - Parameters:
    ///   - order: the sections in the user's order
    ///   - sections: every section, in the default order
    public static func stored(_ order: [AppRoute.Section], sections: [AppRoute.Section] = AppRoute.Section.allCases) -> String {
        order == sections ? "" : order.map(\.rawValue).joined(separator: ",")
    }

    /// Returns the sections the sidebar lists, in the user's order.
    ///
    /// - Parameters:
    ///   - shown: the sections the sidebar lists
    ///   - order: all the sections in the user's order, from ``merged(stored:sections:)``
    public static func ordered(_ shown: [AppRoute.Section], by order: [AppRoute.Section]) -> [AppRoute.Section] {
        order.filter { shown.contains($0) }
    }

    /// Returns the order after a drag in a list of the shown sections: the dragged rows land at the destination, and a
    /// hidden section keeps its place among the others. The offsets are those of SwiftUI's `onMove`.
    ///
    /// - Parameters:
    ///   - order: all the sections in the user's order
    ///   - shown: the sections the list shows, in that order
    ///   - source: the offsets of the dragged rows in `shown`
    ///   - destination: the offset in `shown` the rows are dropped before
    public static func moving(
        _ order: [AppRoute.Section], shown: [AppRoute.Section], from source: IndexSet, to destination: Int
    ) -> [AppRoute.Section] {
        let dragged = source.filter { shown.indices.contains($0) }.map { shown[$0] }
        var reordered = shown.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let position = destination - source.count { $0 < destination }
        reordered.insert(contentsOf: dragged, at: min(max(position, 0), reordered.count))
        var next = reordered.makeIterator()
        return order.map { shown.contains($0) ? (next.next() ?? $0) : $0 }
    }
}
