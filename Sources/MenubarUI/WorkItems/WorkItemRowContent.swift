import MenubarCore
import SwiftUI

/// The work item rows' symbols and caps, shared by the list and the detail.
enum WorkItemRowStyle {
    /// the most of the line the reference takes when the line is short of room
    static let referenceCap: CGFloat = 0.3
    /// the most of the line the slot pill takes when the line is short of room
    static let slotCap: CGFloat = 0.3

    /// The symbols of the markers: two shapes, an open and a merged MR.
    static func symbol(of marker: RelatedMergeRequestMarker) -> String {
        switch marker {
        case .open: "arrow.triangle.pull"
        case .merged: "arrow.triangle.merge"
        }
    }
}

/// A work item's row in the window's list (`docs/design/work-items.md`, Work item row). The marker or the empty symbol
/// column; "#31", the slot's value as a pill in its label's color, then the title, the reference in `.secondary`; and a
/// second line with the type, "Closed" and the labels that tell rows apart. All parts are plain text (WI-04).
struct WorkItemRowContent: View {
    let row: WorkItemRowModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if let marker = row.marker {
                    Image(systemName: WorkItemRowStyle.symbol(of: marker))
                } else {
                    Text(verbatim: " ")
                }
            }
            .frame(width: SectionRowMetrics.symbolColumn)
            VStack(alignment: .leading, spacing: 2) {
                firstLine
                    .help(row.workItem.title)
                if let second = row.secondLine {
                    Text(verbatim: second)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                }
            }
        }
    }

    /// The first line: short of room, the reference (cut in the middle, so its number stays) and the slot pill have
    /// caps, and the title gets the rest, cut at the end (the panel's review PANEL-03 and PANEL-12). From accessibility1
    /// on, one text in up to three lines.
    @ViewBuilder private var firstLine: some View {
        if typeSize.isAccessibilitySize {
            Text("\(Text(verbatim: row.reference).foregroundStyle(.secondary))\(Text(verbatim: "  "))\(Text(verbatim: row.slot.map { "\($0) · " } ?? ""))\(Text(verbatim: row.workItem.displayTitle))")
                .lineLimit(3)
        } else {
            PanelLineLayout {
                Text(verbatim: row.reference)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .panelLineCap(WorkItemRowStyle.referenceCap)
                Text(verbatim: "  ")
                if let slot = row.slotLabel {
                    // The slot's value in the label's color, so the commitment stands out of the title.
                    LabelPill(label: slot, style: .compact)
                        .panelLineCap(WorkItemRowStyle.slotCap)
                    Text(verbatim: "  ")
                }
                Text(verbatim: row.workItem.displayTitle)
            }
            .lineLimit(1)
        }
    }
}
