import Foundation
import MenubarCore
import SwiftUI

/// What the Activity section shows, as plain values: from the ``ActivityStore`` in the app, from fixtures in the
/// gallery (LOG-04, `docs/design/activity.md`).
struct ActivityContentData {
    /// whether the files were read once; before that, placeholder rows show
    var isLoaded: Bool
    /// the shown rows by day, newest first
    var days: [ActivityDay]
    /// why the list is empty; nil when it shows rows, or before the first read
    var emptyState: ActivityEmptyState?
    /// the check times of the last 24 hours
    var chart: CheckTimesChart
    /// how many entries pass the filters and the search
    var matchingCount: Int
    /// how many entries the log has
    var totalCount: Int
    /// whether a filter or the search narrows the list
    var isNarrowed: Bool
    /// the bottom bar's first line, when the list is cut at 1000 rows
    var truncationMessage: String?
    /// the bottom bar's second line, "Since … · 1.2 MB of at most 16.3 MB: …"; nil while the log is empty
    var footerText: String?

    init(
        isLoaded: Bool, days: [ActivityDay], emptyState: ActivityEmptyState?, chart: CheckTimesChart, matchingCount: Int,
        totalCount: Int, isNarrowed: Bool, truncationMessage: String?, footerText: String?
    ) {
        self.isLoaded = isLoaded
        self.days = days
        self.emptyState = emptyState
        self.chart = chart
        self.matchingCount = matchingCount
        self.totalCount = totalCount
        self.isNarrowed = isNarrowed
        self.truncationMessage = truncationMessage
        self.footerText = footerText
    }

    /// What the store holds now.
    @MainActor
    init(store: ActivityStore) {
        let hasEntries = !store.items.isEmpty
        self.init(
            isLoaded: store.isLoaded, days: store.days, emptyState: store.emptyState, chart: store.chart,
            matchingCount: store.matchingItems.count, totalCount: store.items.count,
            isNarrowed: Self.isNarrowed(level: store.levelFilter, source: store.sourceFilter, search: store.searchText),
            truncationMessage: store.truncationMessage, footerText: hasEntries ? store.footerText : nil)
    }

    /// "1 entry" or "N entries": how many pass the filters and the search, at the filter bar's end
    var countText: String {
        Self.entries(matchingCount)
    }

    /// the window's subtitle, ``subtitle(isLoaded:matching:total:isNarrowed:)``
    var subtitle: String? {
        Self.subtitle(isLoaded: isLoaded, matching: matchingCount, total: totalCount, isNarrowed: isNarrowed)
    }

    /// Returns the window's subtitle while Activity shows: how many entries the log has, and while a filter or the
    /// search narrows the list, how many of them show, so the subtitle says the list is limited without naming the
    /// filters, which the filter bar shows ("Clearly display the current scope of a search." [searching]).
    ///
    /// - Parameters:
    ///   - isLoaded: whether the files were read once
    ///   - matching: how many entries pass the filters and the search
    ///   - total: how many entries the log has
    ///   - isNarrowed: whether a filter or the search narrows the list
    /// - Returns: "182 entries", or "12 of 182 entries" while narrowed; nil before the first read or while the log is
    ///   empty
    static func subtitle(isLoaded: Bool, matching: Int, total: Int, isNarrowed: Bool) -> String? {
        guard isLoaded, total > 0 else { return nil }
        return isNarrowed ? "\(matching) of \(entries(total))" : entries(total)
    }

    /// Returns whether the filters or the search narrow the list: a level other than Everything, one source, or a
    /// search with more than spaces.
    ///
    /// - Parameters:
    ///   - level: the level filter
    ///   - source: the source filter; nil for all
    ///   - search: the search text
    /// - Returns: `true` when some entries may be left out
    static func isNarrowed(level: ActivityLevelFilter, source: ActivityEntry.Source?, search: String) -> Bool {
        level != .everything || source != nil || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// "1 entry" or "N entries"
    static func entries(_ count: Int) -> String {
        count == 1 ? "1 entry" : "\(count) entries"
    }
}

/// The rules of the Activity list's multiple selection (LOG-04).
enum ActivitySelection {
    /// What the inspector shows for a selection.
    enum Detail: Equatable {
        /// "No Entry Selected": nothing selected, or every selected entry is gone
        case none
        /// the one selected entry that is still in the log
        case one(ActivityItem)
        /// "3 Entries Selected"
        case several(Int)
    }

    /// Returns what the inspector shows. Entries that Clear or the rotation (LOG-03) removed don't count; a selected
    /// entry the search or the filters hide still does, so it keeps its details (`main-window.md`, Search).
    ///
    /// - Parameters:
    ///   - selection: the selected ids
    ///   - items: every entry of the log, `ActivityStore.items`
    /// - Returns: none, the one entry, or how many
    static func detail(of selection: Set<ActivityItem.ID>, in items: [ActivityItem]) -> Detail {
        guard !selection.isEmpty else { return .none }
        let selected = items.filter { selection.contains($0.id) }
        switch selected.count {
        case 0: return .none
        case 1: return .one(selected[0])
        default: return .several(selected.count)
        }
    }

    /// Returns the selection without the entries that are gone, so Clear and the rotation leave no selection. Before
    /// the first read nothing is known yet, so a restored selection stays (WIN-05).
    ///
    /// - Parameters:
    ///   - selection: the selected ids
    ///   - items: every entry of the log
    ///   - isLoaded: whether the log was read once
    /// - Returns: the ids that are still in the log
    static func pruned(_ selection: Set<ActivityItem.ID>, items: [ActivityItem], isLoaded: Bool) -> Set<ActivityItem.ID> {
        guard isLoaded, !selection.isEmpty else { return selection }
        let ids = Set(items.lazy.map(\.id))
        return selection.filter(ids.contains)
    }

    /// Returns what Copy puts on the clipboard: the selected entries' lines, oldest first, and nothing without a
    /// selection, where Copy is disabled (LOG-04; the user, 2026-10-29: ⌘A, then ⌘C copies every shown entry).
    ///
    /// - Parameters:
    ///   - selection: the selected ids
    ///   - store: the store
    /// - Returns: the lines; nil without a selection
    @MainActor
    static func copyText(of selection: Set<ActivityItem.ID>, in store: ActivityStore) -> String? {
        selection.isEmpty ? nil : store.copyText(of: selection)
    }

    /// A cheap stand-in for the log's entries, to notice that entries came or went without comparing thousands of them.
    struct ItemsKey: Equatable {
        var count: Int
        var newest: ActivityItem.ID?
        var oldest: ActivityItem.ID?

        init(_ items: [ActivityItem]) {
            count = items.count
            newest = items.first?.id
            oldest = items.last?.id
        }
    }
}

/// What the Activity views do, as closures, so the gallery can draw them without a store.
struct ActivityActions {
    /// the lines Copy puts on the clipboard for these ids, oldest first; nil for an empty set
    var copyText: @MainActor (Set<ActivityItem.ID>) -> String?
    /// "Check Now" in "No Activity Yet"
    var checkNow: @MainActor () -> Void
    /// "Show All Entries" in "Nothing to Show": both filters back to their defaults
    var showAllEntries: @MainActor () -> Void
    /// deletes the log, the check times and the kept requests, after the confirmation
    var clear: @MainActor () -> Void

    /// does nothing, for the gallery
    static var none: ActivityActions {
        ActivityActions(copyText: { _ in nil }, checkNow: {}, showAllEntries: {}, clear: {})
    }
}

/// The Activity section's commands for the menu bar: File › Show in Finder, File › Clear Activity… and View › Show
/// Inspector. ``ActivityView`` publishes them with `focusedSceneValue` while it shows; the app's commands read them with
/// `@FocusedValue(\.activityCommands)` and are disabled while they're nil (Activity isn't shown). Edit › Copy is the
/// list's own `onCopyCommand`.
public struct ActivityCommands {
    /// selects the log file in Finder, or opens its folder when there is none yet
    public let showInFinder: @MainActor () -> Void
    /// asks "Clear all activity?" on the window, then clears
    public let clear: @MainActor () -> Void
    /// whether the inspector shows, for the menu item's title
    public let isInspectorShown: Bool
    /// shows the inspector with the selected entry, or hides it
    public let toggleInspector: @MainActor () -> Void

    public init(
        showInFinder: @escaping @MainActor () -> Void, clear: @escaping @MainActor () -> Void, isInspectorShown: Bool,
        toggleInspector: @escaping @MainActor () -> Void
    ) {
        self.showInFinder = showInFinder
        self.clear = clear
        self.isInspectorShown = isInspectorShown
        self.toggleInspector = toggleInspector
    }
}

/// The focused-value key of ``ActivityCommands``.
public struct ActivityCommandsKey: FocusedValueKey {
    public typealias Value = ActivityCommands
}

extension FocusedValues {
    /// the Activity section's menu commands while it shows; nil otherwise
    public var activityCommands: ActivityCommands? {
        get { self[ActivityCommandsKey.self] }
        set { self[ActivityCommandsKey.self] = newValue }
    }
}
