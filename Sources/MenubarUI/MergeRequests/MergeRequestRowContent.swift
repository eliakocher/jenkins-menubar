import MenubarCore
import SwiftUI

/// A merge request's row in the window's list: the panel's MR row in two lines (`docs/design/merge-requests.md`, MR
/// row). The badge symbol in its GitLab color, `.secondary` on a selected row of the focused list; the title cut by
/// width, its tooltip the full title; the MR-03 details, whose reference and badge text truncate last.
struct MergeRequestRowContent: View {
    let row: MergeRequestRowModel
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: row.status.symbol)
                .foregroundStyle(symbolStyle)
                .frame(width: SectionRowMetrics.symbolColumn)
            VStack(alignment: .leading, spacing: 2) {
                // From accessibility1 on, titles take up to three lines and the details wrap, as in the panel.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: row.mergeRequest.title)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        .help(row.mergeRequest.title)
                    Spacer(minLength: 0)
                    // The checkout the branch lives in (WS-07).
                    WorkspaceTag(subject: .mergeRequest(row.mergeRequest))
                }
                details
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The selection's background would swallow GitLab's colors; the badge text still says the state
    /// ([backgroundProminence]).
    private var symbolStyle: AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(row.status.color.swiftUI)
    }

    @ViewBuilder private var details: some View {
        if typeSize.isAccessibilitySize || row.rest.isEmpty {
            Text(verbatim: row.details)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
        } else {
            HStack(spacing: 0) {
                Text(verbatim: row.lead)
                    .layoutPriority(1)
                Text(verbatim: " · \(row.rest)")
            }
            .lineLimit(1)
        }
    }
}
