import Foundation

/// The title of an opened item as the sidebar's row shows it (WIN-06): the team starts MR titles with the work item's
/// number, "#15327 Add the target", which the row moves into a chip of line 2.
public enum OpenedItemTitle {
    /// A title without its leading work item number, and the number.
    public struct Split: Hashable, Sendable {
        /// the title to show
        public var title: String
        /// the work item number the title started with; `nil` when it started with none
        public var workItemNumber: Int?

        public init(title: String, workItemNumber: Int? = nil) {
            self.title = title
            self.workItemNumber = workItemNumber
        }
    }

    /// the markers GitLab reads as a draft, in lowercase
    private static let draftMarkers = ["draft:", "[draft]", "(draft)", "wip:"]

    /// Takes a leading work item number off a title: "#123 Title" and "#123: Title" become "Title", and "Draft: #123 Title"
    /// becomes "Draft: Title", so the draft marker stays. A number in the middle of the title stays, as does a number
    /// followed by more digits or letters ("#123abc"), and a title that is nothing but the number.
    ///
    /// - Parameter title: the item's title
    /// - Returns: the title to show and the number it started with
    public static func split(_ title: String) -> Split {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        var marker = ""
        var rest = Substring(trimmed)
        if let draft = draftMarkers.first(where: { rest.lowercased().hasPrefix($0) }) {
            marker = String(rest.prefix(draft.count))
            rest = rest.dropFirst(draft.count).drop { $0 == " " }
        }
        guard rest.first == "#" else {
            return Split(title: title)
        }
        let afterHash = rest.dropFirst()
        let digits = afterHash.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else {
            return Split(title: title)
        }
        var remainder = afterHash.dropFirst(digits.count)
        // The number ends at a space, a colon or a dash, or at the end of the title.
        if let next = remainder.first, !(next == " " || next == ":" || next == "-" || next == "\u{2013}") {
            return Split(title: title)
        }
        remainder = remainder.drop { $0 == " " }
        if let separator = remainder.first, separator == ":" || separator == "-" || separator == "\u{2013}" {
            remainder = remainder.dropFirst().drop { $0 == " " }
        }
        guard !remainder.isEmpty else {
            return Split(title: title)
        }
        return Split(title: marker.isEmpty ? String(remainder) : "\(marker) \(remainder)", workItemNumber: number)
    }
}
