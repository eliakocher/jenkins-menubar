import MenubarCore
import SwiftUI

/// The header of a slot card (SLOT-15), one row that says how the slot stands even when the card is closed: its name,
/// state and dates on the left; on the right small counters for the done items, the flags and the problems, the number
/// of members, the points and the load bar with its percentage, and a chevron. A click anywhere on it opens or closes
/// the card, and so do ← → and Space while it has the keyboard focus. The numbers are the ones of the chips on.
struct SlotHeader: View {
    let slot: SlotSummary
    let isExpanded: Bool
    /// opens or closes the card; the arrow keys pass what they want
    let setExpanded: (Bool) -> Void
    @ViewState private var isHovering = false
    @FocusState private var isFocused: Bool
    /// a key moved the card since the last click: only then the focus shows, as the chevron's color
    @ViewState private var usedKeyboard = false

    /// how much of the right side fits
    private enum Detail {
        case full, compact, minimal
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(.full)
            row(.compact)
            row(.minimal)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(isHovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            usedKeyboard = false
            setExpanded(!isExpanded)
        }
        .focusable()
        // no system focus ring (a square blue rectangle inside the rounded card); the chevron shows the focus instead
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.leftArrow) {
            usedKeyboard = true
            setExpanded(false)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            usedKeyboard = true
            setExpanded(true)
            return .handled
        }
        .onKeyPress(.space) {
            usedKeyboard = true
            setExpanded(!isExpanded)
            return .handled
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAction { setExpanded(!isExpanded) }
        // No "Collapse 2026.48" tooltip: the chevron says it, and it hid the counters' own tooltips (the user, 2026-11-03).
    }

    private func row(_ detail: Detail) -> some View {
        HStack(alignment: .center, spacing: 14) {
            identity
            Spacer(minLength: 8)
            stats(detail)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isFocused && usedKeyboard ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 14)
                .accessibilityHidden(true)
        }
    }

    // MARK: Left

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                LabelPill(label: LabelPillModel(slot.label), style: .value)
                    .font(.headline)
                    .fixedSize()
                SlotStateBadge(state: slot.state)
                Text(verbatim: slot.countdown)
                    .font(.caption)
                    .foregroundStyle(slot.state == .overdue ? .orange : .secondary)
                    .lineLimit(1)
            }
            Text(verbatim: Self.datesLine(slot.dates))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// "Freeze 20 Nov · Early access 7 Dec · Release 14 Dec", the steps in date order
    static func datesLine(_ dates: SlotDates?) -> String {
        guard let dates else { return "No dates: the name isn't a week like 2026.51" }
        let short = { (date: Date) in date.formatted(.dateTime.day().month(.abbreviated)) }
        let parts = SlotDates.Milestone.allCases.sorted { dates.date(of: $0) < dates.date(of: $1) }.map { milestone in
            let name = milestone == .codeFreeze ? "Freeze" : milestone.title
            return "\(name) \(short(dates.date(of: milestone)))"
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Right

    @ViewBuilder
    private func stats(_ detail: Detail) -> some View {
        HStack(spacing: 10) {
            if detail == .full {
                counters
                if !slot.members.isEmpty {
                    Label(slot.members.count == 1 ? "1 member" : "\(slot.members.count) members", systemImage: "person.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .help("The people with items in this slot")
                }
            }
            if detail != .minimal, !slot.allItems.isEmpty {
                Label {
                    Text(verbatim: "\(slot.points)")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "scalemass")
                }
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize()
                .help(pointsHelp)
            }
            if let load = slot.load {
                HStack(spacing: 6) {
                    SlotLoadBar(load: load, level: slot.loadLevel)
                        .frame(width: detail == .minimal ? 48 : 96)
                    Text(verbatim: "\(Int((load * 100).rounded())) %")
                        .font(.callout.monospacedDigit().weight(.medium))
                        .foregroundStyle(slot.loadColor ?? .secondary)
                        .frame(minWidth: 38, alignment: .trailing)
                        .fixedSize()
                }
                .help(pointsHelp)
            }
        }
    }

    /// the done items, the flags and the problems as small pills
    @ViewBuilder
    private var counters: some View {
        if !slot.allItems.isEmpty {
            SlotCounter(
                symbol: "checkmark.circle", text: "\(slot.allItems.count { $0.isDone })/\(slot.allItems.count)", tint: .secondary,
                help: "\(slot.progressText), \(Int((slot.progress * 100).rounded())) % by weight"
                    + (slot.state == .overdue ? "; \(slot.openItems.count) still open" : ""))
        }
        if slot.weightMissingCount > 0 {
            SlotCounter(
                symbol: SlotProblem.Kind.weightMissing.symbol, text: "\(slot.weightMissingCount)", tint: .orange,
                help: "\(slot.weightMissingCount) open items without a weight: the points and the load leave them out")
        }
        let otherProblems = slot.problemCount - slot.weightMissingCount
        if otherProblems > 0 {
            SlotCounter(
                symbol: "exclamationmark.triangle", text: "\(otherProblems)", tint: .orange,
                help: otherProblems == 1 ? "1 more planning problem" : "\(otherProblems) more planning problems")
        }
        if slot.flagCount > 0 {
            SlotCounter(
                symbol: "flag", text: "\(slot.flagCount)", tint: .red,
                help: slot.flagCount == 1 ? "1 flagged item" : "\(slot.flagCount) flagged items")
        }
        if slot.uncommittedCount > 0 {
            SlotCounter(
                symbol: "circle.dashed", text: "\(slot.uncommittedCount)", tint: .secondary,
                help: slot.uncommittedCount == 1
                    ? "1 item planned for this slot, not committed yet" : "\(slot.uncommittedCount) items planned for this slot, not committed yet")
        }
    }

    private var pointsHelp: String {
        var parts = ["The weight of all \(slot.allItems.count) items, done and planned ones too; \(slot.committedPoints) of it committed."]
        if let capacity = slot.capacity {
            let amount = capacity.formatted(.number.precision(.fractionLength(0...1)))
            if let people = slot.capacityPeople {
                parts.append(
                    "Capacity \(amount) person-days: \(people == 1 ? "1 person" : "\(people) people") with items here, their work days from the code freeze to the release, weekdays only, no time off.")
            } else {
                parts.append("Capacity \(amount) points, the squad capacity.")
            }
        }
        if slot.unweightedCount > 0 {
            parts.append("\(slot.unweightedCount) have no weight and count 0.")
        }
        return parts.joined(separator: " ")
    }
}

/// "OVERDUE" in red, "CURRENT" in green, the quiet "UPCOMING" for the others.
struct SlotStateBadge: View {
    let state: SlotState

    var body: some View {
        Text(verbatim: state.title)
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(state == .upcoming || state == .released ? 0.10 : 0.16), in: Capsule())
            .fixedSize()
    }

    private var tint: Color {
        switch state {
        case .overdue: .red
        case .current: .green
        case .upcoming, .released: .secondary
        }
    }
}

/// A small pill with a symbol and a count.
struct SlotCounter: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary
    let help: String

    var body: some View {
        Label {
            Text(verbatim: text).monospacedDigit()
        } icon: {
            Image(systemName: symbol)
        }
        .labelStyle(CounterLabelStyle())
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
        .fixedSize()
        .help(help)
    }

    private struct CounterLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 3) {
                configuration.icon
                configuration.title
            }
        }
    }
}

/// The load as a bar with the 100 % mark at its end, green below 80 %, amber to 100 %, red above (SLOT-13).
struct SlotLoadBar: View {
    let load: Double
    let level: SlotLoadLevel?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill((color ?? .accentColor).gradient)
                    .frame(width: geometry.size.width * min(load, 1))
                // The 100 % mark, at the end of the track.
                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 1.5)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Load")
        .accessibilityValue("\(Int((load * 100).rounded())) percent")
    }

    private var color: Color? {
        switch level {
        case .fine: .green
        case .tight: .orange
        case .over: .red
        case nil: nil
        }
    }
}

extension SlotSummary {
    /// the color of the load level; `nil` without a load
    var loadColor: Color? {
        switch loadLevel {
        case .fine: .green
        case .tight: .orange
        case .over: .red
        case nil: nil
        }
    }
}
