import MenubarCore
import SwiftUI

/// The Activity inspector's content (Task 5.5, LOG-04): the selected entry with its request and response, or the whole
/// entry when it has none; how many entries are selected; "No Entry Selected" without a selection, and nothing while the
/// list itself is empty.
///
/// It looks the selection up in the store's entries, reads the one entry's details from the store, and draws an
/// ``ActivityDetailPane``; it follows the selection while the inspector shows. The part it shows (Request, Response,
/// Headers) stays across selections, Response first.
public struct ActivityDetailView: View {
    @Environment(ActivityStore.self) private var store
    @AppStorage("activity.detailTab") private var tab = RequestDetailTab.response
    @ViewState private var details: ActivityDetails?
    private let selection: Set<ActivityItem.ID>
    private let close: () -> Void

    /// - Parameters:
    ///   - selection: the selected log entries
    ///   - close: closes the inspector, for the strip's ✕ and Esc
    public init(selection: Set<ActivityItem.ID>, close: @escaping () -> Void) {
        self.selection = selection
        self.close = close
    }

    public var body: some View {
        let detail = ActivitySelection.detail(of: selection, in: store.items)
        ActivityDetailPane(
            detail: detail, details: details, tab: $tab, isListEmpty: !store.isLoaded || store.emptyState != nil,
            close: close, copyCurl: { ActivityPasteboard.put($0.curlCommand) }
        )
        .task(id: entry(of: detail)?.id) {
            guard let item = entry(of: detail), item.hasRequest else {
                details = nil
                return
            }
            let read = await store.details(of: item)
            if !Task.isCancelled {
                details = read
            }
        }
    }

    private func entry(of detail: ActivitySelection.Detail) -> ActivityItem? {
        if case .one(let item) = detail {
            return item
        }
        return nil
    }
}
