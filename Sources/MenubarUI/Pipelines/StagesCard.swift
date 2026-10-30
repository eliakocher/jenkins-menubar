import MenubarCore
import SwiftUI

/// The build detail's Stages card: a strip of one segment per stage, as wide as the stage took, a line counting the
/// outcomes, the few stages that need a look (failed, unstable, running, aborted) with their durations, and the whole
/// list, dense, behind "Show All Stages". A note stands in for the strip while the stages aren't known.
struct StagesCard: View {
    let stages: [BuildDetailModel.StageRow]
    let note: String?

    @ViewState private var showsAll = false
    /// the stage under the pointer in the strip, which the line under it names
    @ViewState private var hovered: Int?
    /// the stage last clicked in the strip, lit in the full list
    @ViewState private var picked: Int?

    var body: some View {
        let attention = stages.filter(\.needsAttention)
        DetailCard("Stages", symbol: "list.bullet.indent") {
            if let note {
                Text(verbatim: note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !stages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    StageStrip(stages: stages, hovered: $hovered) { index in
                        withAnimation(.snappy) {
                            showsAll = true
                            picked = index
                        }
                    }
                    // The hovered stage at once, where a tooltip would wait a second; else the outcomes.
                    if let stage = hovered.flatMap({ index in stages.first { $0.index == index } }) {
                        Text(verbatim: "\(stage.name) · \(stage.word)\(stage.shortDuration.map { " · \($0)" } ?? "")")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(stage.kind == .notRun ? Color.secondary : stage.kind.tint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(verbatim: Self.summary(of: stages))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if !attention.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(attention) { stage in
                            StageLine(stage: stage, dense: false)
                        }
                    }
                }
                if stages.count > attention.count {
                    Button(showsAll ? "Show Fewer Stages" : "Show All Stages (\(String(stages.count)))") {
                        withAnimation(.snappy) {
                            showsAll.toggle()
                            picked = nil
                        }
                    }
                    .buttonStyle(.link)
                    if showsAll {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(stages) { stage in
                                StageLine(stage: stage, dense: true, isPicked: stage.index == picked)
                            }
                        }
                    }
                }
            }
        } accessory: {
            if !stages.isEmpty {
                CountBadge(text: "\(String(stages.count)) stages")
            }
        }
    }

    /// "24 passed · 2 failed · 1 not run", in the order of the strip's severity.
    static func summary(of stages: [BuildDetailModel.StageRow]) -> String {
        let order: [(BuildDetailModel.StageKind, String)] = [
            (.failed, "failed"), (.unstable, "unstable"), (.running, "running"), (.aborted, "aborted"),
            (.success, "passed"), (.notRun, "not run"), (.other, "other"),
        ]
        return order.compactMap { kind, word in
            let count = stages.filter { $0.kind == kind }.count
            return count == 0 ? nil : "\(String(count)) \(word)"
        }
        .joined(separator: " · ")
    }
}

extension BuildDetailModel.StageKind {
    /// the stage's color in the strip and the lines, in the tokens of the merge request detail
    var tint: Color {
        switch self {
        case .success: MergeRequestStatus.Color.green.swiftUI
        case .failed: MergeRequestStatus.Color.red.swiftUI
        case .unstable: MergeRequestStatus.Color.orange.swiftUI
        case .running: MergeRequestStatus.Color.blue.swiftUI
        case .aborted, .notRun, .other: MergeRequestStatus.Color.neutral.swiftUI
        }
    }
}

/// One stage as a line: its symbol, name, outcome word where it isn't plain, and duration, right-aligned in digits that
/// don't jump. It lights up on hover.
private struct StageLine: View {
    let stage: BuildDetailModel.StageRow
    let dense: Bool
    /// whether the stage was clicked in the strip: lit in its color
    var isPicked = false
    @ViewState private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: stage.symbol)
                .foregroundStyle(stage.kind == .notRun ? Color.secondary : stage.kind.tint)
                .font(dense ? .callout : .body)
                .frame(width: 16)
            Text(verbatim: stage.name)
                .font(dense ? .callout : .body)
                .foregroundStyle(stage.kind == .notRun ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if !dense {
                Text(verbatim: stage.word)
                    .font(.callout)
                    .foregroundStyle(stage.kind.tint)
                    .fixedSize()
            }
            Text(verbatim: stage.shortDuration ?? "")
                .font(dense ? .callout : .body)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, dense ? 3 : 5)
        .background(
            isPicked ? AnyShapeStyle(stage.kind.tint.opacity(0.18)) : AnyShapeStyle(.fill.quaternary.opacity(isHovered ? 1 : 0)),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// One segment per stage in a row, each as wide as its stage took (with a floor, so a short stage stays visible), in
/// the stage's color; the tooltip names the stage, its outcome and its duration.
private struct StageStrip: View {
    let stages: [BuildDetailModel.StageRow]
    @Binding var hovered: Int?
    /// a click on a segment, with its stage's index
    let pick: (Int) -> Void

    var body: some View {
        let total = stages.reduce(0) { $0 + $1.seconds }
        let floor = max(total * 0.03, 1)
        StageStripLayout {
            ForEach(stages) { stage in
                StageSegment(stage: stage, isHovered: hovered == stage.index) { inside in
                    if inside {
                        hovered = stage.index
                    } else if hovered == stage.index {
                        hovered = nil
                    }
                } pick: {
                    pick(stage.index)
                }
                .layoutValue(key: StageWeightKey.self, value: max(stage.seconds, floor))
            }
        }
        // The summary line and the list say it in words; the segments are for the pointer.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StagesCard.summary(of: stages))
    }
}

/// A stage's segment: brighter and a touch taller under the pointer; a click shows it in the full list.
private struct StageSegment: View {
    let stage: BuildDetailModel.StageRow
    let isHovered: Bool
    let hover: (Bool) -> Void
    let pick: () -> Void

    var body: some View {
        let tint = stage.kind.tint
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(tint.opacity(stage.kind == .notRun ? (isHovered ? 0.45 : 0.25) : (isHovered ? 1 : 0.75)))
            .scaleEffect(y: isHovered ? 1.3 : 1)
            .animation(.snappy(duration: 0.15), value: isHovered)
            .contentShape(.rect)
            .onHover(perform: hover)
            .onTapGesture(perform: pick)
            .help("\(stage.name) · \(stage.word)\(stage.shortDuration.map { " · \($0)" } ?? "")")
    }
}

private struct StageWeightKey: LayoutValueKey {
    static let defaultValue: Double = 1
}

/// A single row of the subviews, each as wide as its weight says of the row's width.
private struct StageStripLayout: Layout {
    var spacing: CGFloat = 2
    var height: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 200, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let weights = subviews.map { $0[StageWeightKey.self] }
        let sum = max(weights.reduce(0, +), 0.001)
        let available = bounds.width - spacing * CGFloat(max(0, subviews.count - 1))
        var x = bounds.minX
        for (subview, weight) in zip(subviews, weights) {
            let width = available * CGFloat(weight / sum)
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: height))
            x += width + spacing
        }
    }
}
