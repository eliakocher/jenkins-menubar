import AppKit
import MenubarCore
import SwiftUI

/// How the Activity log's selection reacts to clicks and arrow keys, as a `List` did before the rows drew their own
/// highlight inside the content width: a click selects one entry, ⌘ toggles one, ⇧ extends from the anchor; ↑ and ↓
/// move by one (clamped at the ends), ⇧ extends, Home and End go to the ends. Pure, so a test checks it.
struct ActivityListSelection: Equatable {
    var selected: Set<ActivityItem.ID> = []
    /// where a ⇧-range starts
    var anchor: ActivityItem.ID?
    /// the entry the keys move from: the last one clicked or moved to
    var cursor: ActivityItem.ID?

    enum Step {
        case previous
        case next
        case first
        case last
    }

    /// Applies a click on an entry.
    ///
    /// - Parameters:
    ///   - id: the clicked entry
    ///   - ordered: every shown entry, top to bottom
    ///   - toggle: whether ⌘ was held
    ///   - extend: whether ⇧ was held
    mutating func click(_ id: ActivityItem.ID, in ordered: [ActivityItem.ID], toggle: Bool, extend: Bool) {
        if extend, let anchor, let range = Self.range(from: anchor, to: id, in: ordered) {
            selected = range
        } else if toggle {
            if selected.contains(id) {
                selected.remove(id)
            } else {
                selected.insert(id)
            }
            anchor = id
        } else {
            selected = [id]
            anchor = id
        }
        cursor = id
    }

    /// Moves the cursor by a key.
    ///
    /// - Parameters:
    ///   - step: where to
    ///   - ordered: every shown entry, top to bottom
    ///   - extend: whether ⇧ was held
    /// - Returns: the entry that is now the cursor, nil when the list is empty
    @discardableResult
    mutating func move(_ step: Step, in ordered: [ActivityItem.ID], extend: Bool) -> ActivityItem.ID? {
        guard !ordered.isEmpty else { return nil }
        let from = cursor.flatMap { ordered.firstIndex(of: $0) } ?? ordered.firstIndex { selected.contains($0) }
        let target: Int
        switch step {
        case .first: target = 0
        case .last: target = ordered.count - 1
        case .previous: target = from.map { max($0 - 1, 0) } ?? ordered.count - 1
        case .next: target = from.map { min($0 + 1, ordered.count - 1) } ?? 0
        }
        let id = ordered[target]
        click(id, in: ordered, toggle: false, extend: extend)
        return id
    }

    private static func range(from: ActivityItem.ID, to: ActivityItem.ID, in ordered: [ActivityItem.ID]) -> Set<ActivityItem.ID>? {
        guard let a = ordered.firstIndex(of: from), let b = ordered.firstIndex(of: to) else { return nil }
        return Set(ordered[min(a, b)...max(a, b)])
    }
}

/// The log by day: rows that draw their own tint, selection and divider inside the content width, with the sticky day
/// headings and the scroll bar across the window (a `List` fills its rows' backgrounds to its edges, so it can't keep
/// them in a capped column). It does what the `List` did: click, ⌘ and ⇧ selection, ↑ ↓ Home End, Return and
/// double click for the details, the context menu, Edit › Copy.
struct ActivityLogList: View {
    let days: [ActivityDay]
    @Binding var selection: Set<ActivityItem.ID>
    let isCompact: Bool
    /// the space to leave free on each side so the rows keep to the content width
    let margin: CGFloat
    @FocusState.Binding var isFocused: Bool
    /// shows the inspector with these entries
    let inspect: (Set<ActivityItem.ID>) -> Void
    /// Escape, with the list focused
    let dismiss: () -> Void
    let copy: (Set<ActivityItem.ID>) -> Void
    let proxy: ScrollViewProxy

    @ViewState private var state = ActivityListSelection()

    /// the text column's distance from the row's edge, in points
    static let inset: CGFloat = 20

    private var ordered: [ActivityItem.ID] {
        days.flatMap { $0.items.map(\.id) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(days) { day in
                    Section {
                        ForEach(day.items) { item in
                            row(item)
                        }
                    } header: {
                        DayHeading(title: day.title, margin: margin)
                    }
                }
            }
        }
        .background(.background)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: [.down, .repeat]) { press in
            handle(press)
        }
        .onChange(of: selection) {
            // Selected from outside (the inspector's rows, a restored selection): the keys continue from there.
            if state.selected != selection {
                state = ActivityListSelection(selected: selection, anchor: selection.first, cursor: selection.first)
            }
        }
    }

    // MARK: Rows

    private func row(_ item: ActivityItem) -> some View {
        let isSelected = selection.contains(item.id)
        let style = ActivityRowStyle(isSelected: isSelected, isFocused: isFocused)
        return ActivityRow(item: item, isCompact: isCompact) { inspect([item.id]) }
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 5)
            .foregroundStyle(style.foreground)
            .environment(\.backgroundProminence, style.prominence)
            .background {
                ZStack {
                    if !isSelected, let tint = ActivityRowTint.color(of: item.entry.level) {
                        Rectangle().fill(tint)
                    }
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(style.fill)
                            .padding(.horizontal, 5)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                Divider()
                    .padding(.horizontal, Self.inset)
                    .opacity(isSelected ? 0 : 1)
            }
            .padding(.horizontal, margin)
            .contentShape(Rectangle())
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                state.click(item.id, in: ordered, toggle: flags.contains(.command), extend: flags.contains(.shift))
                selection = state.selected
                isFocused = true
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    selection = [item.id]
                    state = ActivityListSelection(selected: [item.id], anchor: item.id, cursor: item.id)
                    inspect([item.id])
                }
            )
            .contextMenu {
                let ids = selection.contains(item.id) ? selection : [item.id]
                Button("Show Details") { inspect(ids) }
                Button("Copy") { copy(ids) }
            }
            .id(item.id)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Keys

    private func handle(_ press: SwiftUI.KeyPress) -> SwiftUI.KeyPress.Result {
        let extend = press.modifiers.contains(.shift)
        let step: ActivityListSelection.Step
        switch press.key {
        case .upArrow: step = .previous
        case .downArrow: step = .next
        case .home: step = .first
        case .end: step = .last
        case .return:
            guard !selection.isEmpty else { return .ignored }
            inspect(selection)
            return .handled
        case .escape:
            dismiss()
            return .handled
        default:
            if press.characters == "a", press.modifiers.contains(.command) {
                selection = Set(ordered)
                state = ActivityListSelection(selected: selection, anchor: ordered.first, cursor: ordered.last)
                return .handled
            }
            return .ignored
        }
        if let id = state.move(step, in: ordered, extend: extend) {
            selection = state.selected
            // Without an anchor: the least scroll that shows the row.
            proxy.scrollTo(id)
        }
        return .handled
    }
}

/// How a row looks selected: the system's accent fill with white text while the list has the focus, the quiet grey of
/// an inactive selection without it.
private struct ActivityRowStyle {
    let isSelected: Bool
    let isFocused: Bool

    var fill: Color {
        isFocused ? Color.accentColor : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }

    var foreground: AnyShapeStyle {
        isSelected && isFocused ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary)
    }

    /// `.increased` on a selected row of the focused list, so the pills give up their colors as they did in a `List`
    var prominence: BackgroundProminence {
        isSelected && isFocused ? .increased : .standard
    }
}

/// A day's sticky heading: opaque, so the rows scroll under it cleanly, with a hairline under it.
private struct DayHeading: View {
    let title: String
    let margin: CGFloat

    var body: some View {
        Text(verbatim: title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, ActivityLogList.inset + margin)
            .padding(.top, 12)
            .padding(.bottom, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
            .overlay(alignment: .bottom) { Divider() }
    }
}
