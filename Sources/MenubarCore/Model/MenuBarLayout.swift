import Foundation

/// What the menu bar shows (APP-11): the status item's parts in their order, each on or off, and the menu pane's rows
/// with their flyouts, edited in Settings → Menu Bar. The defaults are the look from before it existed.
///
/// It is kept as JSON text in one key (``PreferencesStore/menuBarLayoutKey``). A saved layout survives updates the way
/// ``SectionOrder`` does: an id that isn't a part or a row any more is dropped, and one it doesn't list yet takes its
/// default place, right after the one before it in the default order, with its default switch.
///
/// The status item redraws on every check, so the layout is a plain value the label reads once per update.
public struct MenuBarLayout: Codable, Hashable, Sendable {
    /// A part of the status item after the butler, in the default order.
    public enum ItemPart: String, Codable, Hashable, Sendable, CaseIterable {
        /// the problem marker: Jenkins, the team values, offline (PIPE-05)
        case problem
        case running
        case failed
        case unstable
        case successful
        /// the Inbox, as a red dot or its count (``InboxStyle``) (INBOX-09)
        case inbox
        /// the merge requests that wait for my review
        case reviews
        /// the next date of my committed slot: "freeze 3d" (SLOT-02)
        case slot

        /// the build kind it counts; `nil` for the other parts
        public var buildKind: BuildCounts.Kind? {
            switch self {
            case .running: .running
            case .failed: .failed
            case .unstable: .unstable
            case .successful: .successful
            default: nil
            }
        }

        /// whether it is on before anyone changed the layout: everything the item showed before, not the new parts
        public var isOnByDefault: Bool {
            self != .reviews && self != .slot
        }
    }

    /// When the butler shows.
    public enum Butler: String, Codable, Hashable, Sendable, CaseIterable {
        /// while no build is counted (the default, as before)
        case whenIdle
        /// always, before the other parts
        case always
        /// only while nothing else shows, so the item never is empty and can still be clicked
        case never
    }

    /// How the Inbox shows when its part is on.
    public enum InboxStyle: String, Codable, Hashable, Sendable, CaseIterable {
        /// a small red dot (the default, as before)
        case dot
        /// the badge's number with the tray symbol
        case count
    }

    /// The menu pane's width.
    public enum PaneWidth: String, Codable, Hashable, Sendable, CaseIterable {
        case compact
        /// the width from before (the default)
        case regular
        case wide
    }

    /// A part of the status item and whether it shows.
    public struct Part: Codable, Hashable, Sendable, Identifiable {
        public var part: ItemPart
        public var isOn: Bool

        public init(_ part: ItemPart, isOn: Bool) {
            self.part = part
            self.isOn = isOn
        }

        public var id: ItemPart { part }
    }

    /// A row of the menu pane: one area, whether it shows, whether it opens a flyout and how many entries that lists.
    public struct Row: Encodable, Hashable, Sendable, Identifiable {
        public var section: AppRoute.Section
        public var isOn: Bool
        /// whether hovering the row opens its list beside the pane; off, a click opens the main window there
        public var showsFlyout: Bool
        /// the most entries the flyout lists, one of ``MenuBarLayout/flyoutRowOptions``
        public var flyoutRows: Int

        public init(
            _ section: AppRoute.Section, isOn: Bool = true, showsFlyout: Bool = true,
            flyoutRows: Int = MenuBarLayout.defaultFlyoutRows
        ) {
            self.section = section
            self.isOn = isOn
            self.showsFlyout = showsFlyout
            self.flyoutRows = flyoutRows
        }

        public var id: AppRoute.Section { section }

        private enum CodingKeys: String, CodingKey {
            case section, isOn, showsFlyout, flyoutRows
        }

        // The section by its link name; the layout decodes rows itself, tolerant of names that are gone.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(section.rawValue, forKey: .section)
            try container.encode(isOn, forKey: .isOn)
            try container.encode(showsFlyout, forKey: .showsFlyout)
            try container.encode(flyoutRows, forKey: .flyoutRows)
        }
    }

    /// 5, 10 or 20 (the default, as before) entries in a flyout
    public static let flyoutRowOptions = [5, 10, 20]
    public static let defaultFlyoutRows = 20
    /// the sections that have a row in the pane, in the default order
    public static let paneSections: [AppRoute.Section] = [.pipelines, .inbox, .mergeRequests, .workItems]

    public var butler: Butler
    /// every part once, in the user's order
    public var parts: [Part]
    public var inboxStyle: InboxStyle
    /// whether a count of 0 is left out (the default, as before); off, every count that is on shows, 0 too
    public var hidesZeroCounts: Bool
    /// every pane row once, in the user's order
    public var rows: [Row]
    public var paneWidth: PaneWidth

    public init(
        butler: Butler = .whenIdle, parts: [Part] = MenuBarLayout.defaultParts, inboxStyle: InboxStyle = .dot,
        hidesZeroCounts: Bool = true, rows: [Row] = MenuBarLayout.defaultRows, paneWidth: PaneWidth = .regular
    ) {
        self.butler = butler
        self.parts = Self.merged(parts, defaults: Self.defaultParts, id: \.part)
        self.inboxStyle = inboxStyle
        self.hidesZeroCounts = hidesZeroCounts
        self.rows = Self.merged(rows, defaults: Self.defaultRows, id: \.section).map(Self.validated)
        self.paneWidth = paneWidth
    }

    /// the parts as the item showed them before the layout: the problem, the four counts, the Inbox dot; the new ones off
    public static let defaultParts: [Part] = ItemPart.allCases.map { Part($0, isOn: $0.isOnByDefault) }
    /// the pane's rows as before: all four, each with its flyout of 20
    public static let defaultRows: [Row] = paneSections.map { Row($0) }

    // MARK: - What shows

    /// Returns whether a part is on.
    public func isOn(_ part: ItemPart) -> Bool {
        parts.first { $0.part == part }?.isOn ?? part.isOnByDefault
    }

    /// the parts that are on, in order
    public var shownParts: [ItemPart] {
        parts.filter(\.isOn).map(\.part)
    }

    /// the pane's rows that are on, in order
    public var shownRows: [Row] {
        rows.filter(\.isOn)
    }

    /// Returns a pane row's settings; the default for a section without a row.
    public func row(_ section: AppRoute.Section) -> Row {
        rows.first { $0.section == section } ?? Row(section)
    }

    /// whether the item part of the layout is as it was before the layout existed
    public var isDefaultItem: Bool {
        var item = self
        item.rows = Self.defaultRows
        item.paneWidth = .regular
        return item == MenuBarLayout()
    }

    /// whether the pane part of the layout is as it was before the layout existed
    public var isDefaultPane: Bool {
        rows == Self.defaultRows && paneWidth == .regular
    }

    /// Puts the item's settings back to their defaults and keeps the pane's.
    public mutating func resetItem() {
        let defaults = MenuBarLayout()
        butler = defaults.butler
        parts = defaults.parts
        inboxStyle = defaults.inboxStyle
        hidesZeroCounts = defaults.hidesZeroCounts
    }

    /// Puts the pane's settings back to their defaults and keeps the item's.
    public mutating func resetPane() {
        rows = Self.defaultRows
        paneWidth = .regular
    }

    /// Turns a part on or off where it is.
    public mutating func setPart(_ part: ItemPart, isOn: Bool) {
        if let index = parts.firstIndex(where: { $0.part == part }) {
            parts[index].isOn = isOn
        }
    }

    /// Changes a pane row where it is; a flyout's number of rows outside the options gets the default.
    public mutating func updateRow(_ section: AppRoute.Section, _ change: (inout Row) -> Void) {
        if let index = rows.firstIndex(where: { $0.section == section }) {
            change(&rows[index])
            rows[index] = Self.validated(rows[index])
        }
    }

    /// Moves parts as SwiftUI's `onMove` does.
    public mutating func moveParts(from source: IndexSet, to destination: Int) {
        parts = Self.moving(parts, from: source, to: destination)
    }

    /// Moves pane rows as SwiftUI's `onMove` does.
    public mutating func moveRows(from source: IndexSet, to destination: Int) {
        rows = Self.moving(rows, from: source, to: destination)
    }

    /// what the log says after a change: the parts that are on, the pane's rows that are on, and what differs
    public var summary: String {
        let item = shownParts.map { $0 == .inbox ? "inbox \(inboxStyle.rawValue)" : $0.rawValue }
        let pane = shownRows.map { row in
            row.section.rawValue + (row.showsFlyout ? (row.flyoutRows == Self.defaultFlyoutRows ? "" : " \(row.flyoutRows)") : " no flyout")
        }
        var text = "item: butler \(butler.rawValue), \(item.joined(separator: ", "))"
        if !hidesZeroCounts {
            text += ", zero counts"
        }
        return text + "; pane: \(pane.joined(separator: ", ")), \(paneWidth.rawValue)"
    }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case butler, parts, inboxStyle, hidesZeroCounts, rows, paneWidth
    }

    /// A part as it was saved, with an id that may be no part any more.
    private struct StoredPart: Decodable {
        var part: String
        var isOn: Bool?
    }

    /// A row as it was saved, with an id that may be no row any more.
    private struct StoredRow: Decodable {
        var section: String
        var isOn: Bool?
        var showsFlyout: Bool?
        var flyoutRows: Int?
    }

    // Anything missing, unknown or of the wrong type reads as its default, so a layout from an older or a newer version
    // always decodes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MenuBarLayout()
        func value<Value: Decodable>(_ key: CodingKeys, _ fallback: Value) -> Value {
            ((try? container.decodeIfPresent(Value.self, forKey: key)) ?? nil) ?? fallback
        }
        let storedParts = value(.parts, [LossyElement<StoredPart>]()).compactMap(\.value)
        let parts = storedParts.compactMap { stored in
            ItemPart(rawValue: stored.part).map { Part($0, isOn: stored.isOn ?? $0.isOnByDefault) }
        }
        let storedRows = value(.rows, [LossyElement<StoredRow>]()).compactMap(\.value)
        let rows = storedRows.compactMap { stored -> Row? in
            guard let section = AppRoute.Section(rawValue: stored.section), Self.paneSections.contains(section) else {
                return nil
            }
            return Row(
                section, isOn: stored.isOn ?? true, showsFlyout: stored.showsFlyout ?? true,
                flyoutRows: stored.flyoutRows ?? Self.defaultFlyoutRows)
        }
        self.init(
            butler: value(.butler, defaults.butler), parts: parts, inboxStyle: value(.inboxStyle, defaults.inboxStyle),
            hidesZeroCounts: value(.hidesZeroCounts, defaults.hidesZeroCounts), rows: rows,
            paneWidth: value(.paneWidth, defaults.paneWidth))
    }

    /// An element of a list that decodes to `nil` instead of failing the whole list.
    private struct LossyElement<Element: Decodable>: Decodable {
        var value: Element?

        init(from decoder: any Decoder) throws {
            value = try? Element(from: decoder)
        }
    }

    // MARK: - Merging

    /// Returns every default entry once: the saved ones in their order, repeats and unknown ids dropped, the ones the
    /// saved list lacks after their default predecessor (``SectionOrder/merged(stored:sections:)``'s rule).
    static func merged<Entry, ID: Hashable>(_ saved: [Entry], defaults: [Entry], id: KeyPath<Entry, ID>) -> [Entry] {
        let known = Set(defaults.map { $0[keyPath: id] })
        var result: [Entry] = []
        var seen: Set<ID> = []
        for entry in saved where known.contains(entry[keyPath: id]) && !seen.contains(entry[keyPath: id]) {
            result.append(entry)
            seen.insert(entry[keyPath: id])
        }
        for (index, entry) in defaults.enumerated() where !seen.contains(entry[keyPath: id]) {
            var position = 0
            for earlier in defaults[..<index].reversed() {
                if let found = result.firstIndex(where: { $0[keyPath: id] == earlier[keyPath: id] }) {
                    position = found + 1
                    break
                }
            }
            result.insert(entry, at: position)
            seen.insert(entry[keyPath: id])
        }
        return result
    }

    private static func moving<Entry>(_ entries: [Entry], from source: IndexSet, to destination: Int) -> [Entry] {
        let dragged = source.filter { entries.indices.contains($0) }.map { entries[$0] }
        var rest = entries.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let position = destination - source.count { $0 < destination }
        rest.insert(contentsOf: dragged, at: min(max(position, 0), rest.count))
        return rest
    }

    /// A row with a number of flyout rows outside the options gets the default.
    private static func validated(_ row: Row) -> Row {
        var row = row
        if !flyoutRowOptions.contains(row.flyoutRows) {
            row.flyoutRows = defaultFlyoutRows
        }
        return row
    }
}
