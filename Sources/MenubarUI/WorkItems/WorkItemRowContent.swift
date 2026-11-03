import MenubarCore
import SwiftUI

/// The work item rows' caps, shared by the list and the detail.
enum WorkItemRowStyle {
    /// the most of the line the reference takes when the line is short of room
    static let referenceCap: CGFloat = 0.3
    /// the most of the line the slot pill takes when the line is short of room
    static let slotCap: CGFloat = 0.3
    /// the most of the line the merge request chip takes when the line is short of room
    static let chipCap: CGFloat = 0.4
}

/// A work item's row in the window's list, in the shape the three lists share (``ListRow``; `docs/design/work-items.md`,
/// Work item row). No symbol column, so the text starts at the row's edge (the user, 2026-11-02); the title in up to two
/// lines, "updated 5m ago" at the right end; and line 2 (``WorkItemDetailsLine``) with "#31", the slot's value as a
/// pill in its label's color, the merge request chip ("!14 +1", ``WorkItemMergeRequestChip``), then the type, "Closed"
/// and the labels that tell rows apart. All parts are plain text (WI-04).
struct WorkItemRowContent: View {
    let row: WorkItemRowModel

    var body: some View {
        ListRow(title: row.workItem.displayTitle) {
            ListRowTime(text: row.age, help: "Updated \(row.age)")
        } details: {
            WorkItemDetailsLine(row: row)
                .help(WorkItemDetailsLine.plainText(of: row))
        }
    }
}

/// A work item row's line 2, shared by the window's list and the menu bar pane's flyout: short of room, the reference
/// (cut in the middle, so its number stays), the slot pill and the MR chip have caps, and the labels get the rest, cut
/// at the end: they go first, then the chip and the pill shrink, the reference stays (the panel's review PANEL-03 and
/// PANEL-12). From accessibility1 on, one text that wraps. The text takes the surrounding secondary style.
struct WorkItemDetailsLine: View {
    let row: WorkItemRowModel
    @Environment(\.dynamicTypeSize) private var typeSize

    /// the reference, the slot and the second line in one text, for the tooltip and the accessibility sizes
    static func plainText(of row: WorkItemRowModel) -> String {
        ([row.reference, row.slot, row.mergeRequestChip?.text].compactMap { $0 } + [row.secondLine].compactMap { $0 })
            .joined(separator: " · ")
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            Text(verbatim: Self.plainText(of: row))
        } else {
            PanelLineLayout {
                // The number as a small blue chip (the user, 2026-11-03).
                WorkItemNumberChip(text: row.reference)
                    .panelLineCap(WorkItemRowStyle.referenceCap)
                if let slot = row.slotLabel {
                    Text(verbatim: " ")
                    // The slot's value in the label's color, so the commitment stands out of the labels.
                    LabelPill(label: slot, style: .compact)
                        .panelLineCap(WorkItemRowStyle.slotCap)
                }
                if let chip = row.mergeRequestChip {
                    Text(verbatim: " ")
                    WorkItemMergeRequestChipView(chip: chip)
                        .panelLineCap(WorkItemRowStyle.chipCap)
                }
                if let second = row.secondLine {
                    // After the chips no dot: the chips already set the facts apart.
                    Text(verbatim: "  \(second)")
                } else {
                    Text(verbatim: "")
                }
            }
            .lineLimit(1)
        }
    }
}

/// The merge request chip: "!14 +1" in the merge request green, whatever the state (the user, 2026-11-03); the tooltip
/// lists the MRs with their states and titles. Chip and number are ``MergeRequestNumberChip``'s.
struct WorkItemMergeRequestChipView: View {
    let chip: WorkItemMergeRequestChip

    var body: some View {
        MergeRequestNumberChip(text: chip.text ?? "!", help: chip.help)
    }
}
