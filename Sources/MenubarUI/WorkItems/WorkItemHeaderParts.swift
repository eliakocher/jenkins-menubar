import MenubarCore
import SwiftUI

/// The labels no fact of the work item header shows (WI-04), quiet: up to three as small pills; more as the first two
/// and "+N", which opens them all, and "Show Less" closes them again.
struct WorkItemOtherLabels: View {
    let labels: [LabelPillModel]

    @ViewState private var isOpen = false

    /// the most labels shown whole before the rest fold behind "+N"
    private static let shownClosed = 3

    var body: some View {
        let folds = labels.count > Self.shownClosed
        let shown = folds && !isOpen ? Array(labels.prefix(Self.shownClosed - 1)) : labels
        PillFlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(shown) { LabelPill(label: $0, small: true) }
            if folds {
                Button {
                    withAnimation(.snappy) { isOpen.toggle() }
                } label: {
                    Text(verbatim: isOpen ? "Show Less" : "+\(labels.count - shown.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(.fill.secondary, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Show fewer labels" : labels.dropFirst(shown.count).map(\.title).joined(separator: ", "))
            }
        }
    }
}

/// A small, quiet button after the work item's reference in its detail header that copies the team's branch name for
/// it, like `18874-fix-the-thing` (``CopyBranchNameButton/copy(_:)``), and shows a check for a moment.
struct BranchNameCopyButton: View {
    let workItem: WorkItem

    @ViewState private var copied = false
    @ViewState private var isHovered = false

    var body: some View {
        Button {
            CopyBranchNameButton.copy(workItem)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "arrow.triangle.branch")
                .font(.callout)
                .foregroundStyle(copied ? AnyShapeStyle(MergeRequestStatus.Color.green.swiftUI) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 20)
                .background(.fill.tertiary.opacity(isHovered ? 1 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Copy Branch Name")
        .accessibilityLabel("Copy Branch Name")
    }
}
