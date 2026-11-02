import MenubarCore
import SwiftUI

/// A merge request's row in the window's list, in the shape the three lists share (``ListRow``): the badge symbol in its
/// GitLab color, `.secondary` on a selected row of the focused list; the title in up to two lines, its tooltip the full
/// title; the checkout's tag and "updated 5m ago" at the right end; and the MR-03 details on line 2, whose pipeline, diff
/// stats and author drop in that order when the column is narrow, the reference and the badge text last
/// (`docs/design/merge-requests.md`, MR row). The tooltip of the details has them whole.
struct MergeRequestRowContent: View {
    let row: MergeRequestRowModel
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        ListRow(title: row.mergeRequest.title) {
            Image(systemName: row.status.symbol)
                .foregroundStyle(symbolStyle)
        } trailing: {
            // The checkout the branch lives in (WS-07).
            WorkspaceTag(subject: .mergeRequest(row.mergeRequest))
            ListRowTime(text: row.age, help: "Updated \(row.age)")
        } details: {
            DetailsLine(lead: row.lead, more: row.more, reference: row.shortReference)
                .help(row.details)
        }
    }

    /// The selection's background would swallow GitLab's colors; the badge text still says the state
    /// ([backgroundProminence]).
    private var symbolStyle: AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(row.status.color.swiftUI)
    }
}
