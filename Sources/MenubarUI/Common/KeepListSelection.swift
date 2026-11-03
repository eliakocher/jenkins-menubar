import AppKit
import SwiftUI

/// The rule of every list that has a detail beside it: a click on the list's empty space, on a section header or on a
/// footer row's blank area keeps the selection, so the detail never goes blank. Only a click on another row changes it.
/// Without it AppKit's table deselects on such a click and `List(selection:)` writes `nil`, which empties the detail.
///
/// Two parts work together, because neither is enough alone (probed in an offscreen window, 2026-11-03: a `List` that
/// only refuses the `nil` write stays visually deselected, since the unchanged value gives SwiftUI no reason to select
/// the row again):
/// - ``keepsSelection()``: the list's table gets `allowsEmptySelection = false`, so AppKit keeps the row selected and
///   never reports the click. A selection that is cleared by code (the row left the list, Back to a state without
///   one) still works and doesn't pick another row.
/// - ``Binding/keepingSelection()``: the binding handed to `List(selection:)` refuses a `nil` that gets through anyway.
///
/// Code that clears the selection on purpose writes the underlying value and is not affected.
enum KeepListSelection {
    /// Returns the selection after the list wrote `proposed`: a row replaces it, `nil` (a click on nothing) doesn't.
    ///
    /// - Parameters:
    ///   - proposed: what `List` wrote
    ///   - current: the selection before
    static func resolved<ID>(proposed: ID?, current: ID?) -> ID? {
        proposed ?? current
    }

    /// Returns the selection to keep after the list's rows changed: the selected row if it is still there, or wasn't
    /// in the list before (opened from another section, restored); else its nearest neighbour, the next row that is
    /// still there, or the previous one. An emptied list keeps the selection (a reload, a failed check): the detail is
    /// blank while the row is away, and it comes back with the row.
    ///
    /// - Parameters:
    ///   - selected: the selection
    ///   - old: the selectable rows' ids, in order, before the change
    ///   - new: the same after it
    static func kept<ID: Equatable>(_ selected: ID, from old: [ID], to new: [ID]) -> ID {
        guard !new.isEmpty, !new.contains(selected), let index = old.firstIndex(of: selected) else {
            return selected
        }
        let following = old[(index + 1)...].first { new.contains($0) }
        return following ?? old[..<index].last { new.contains($0) } ?? selected
    }

    /// Finds the table of the list that `anchor` sits behind: the first table among the siblings of the anchor or of
    /// its nearest ancestor that has one, so another list (the sidebar) isn't reached.
    @MainActor
    static func table(near anchor: NSView) -> NSTableView? {
        var node: NSView? = anchor
        while let current = node, let parent = current.superview {
            for sibling in parent.subviews where sibling !== current {
                if let table = firstTable(in: sibling) {
                    return table
                }
            }
            node = parent
        }
        return nil
    }

    @MainActor
    private static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView {
            return table
        }
        for subview in view.subviews {
            if let table = firstTable(in: subview) {
                return table
            }
        }
        return nil
    }
}

extension Binding {
    /// A binding for `List(selection:)` that keeps the selection when the list writes `nil`.
    func keepingSelection<ID>() -> Binding<ID?> where Value == ID? {
        Binding<ID?>(
            get: { wrappedValue },
            set: { proposed in
                wrappedValue = KeepListSelection.resolved(proposed: proposed, current: wrappedValue)
            })
    }
}

extension View {
    /// Keeps a `List`'s selected row selected when the user clicks the list's empty space (put it on the `List`; see
    /// ``KeepListSelection``). For a list with one selected row and a detail beside it, not for a multi-selection.
    func keepsSelection() -> some View {
        background(KeepSelectionAnchor())
    }
}

/// An invisible view behind a `List` that switches off its table's empty selection.
private struct KeepSelectionAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> KeepSelectionAnchorView {
        let view = KeepSelectionAnchorView()
        view.schedule()
        return view
    }

    func updateNSView(_ view: KeepSelectionAnchorView, context: Context) {
        view.apply()
        view.schedule()
    }
}

/// The anchor's view: it looks for its list's table once the list has made it (a `List` builds the table lazily), and
/// again after every update, as SwiftUI may build the table anew.
final class KeepSelectionAnchorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    /// Looks for the table after this turn of the run loop, a few times if the list hasn't built it yet.
    func schedule(attempt: Int = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.apply(), attempt < 10 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.schedule(attempt: attempt + 1)
            }
        }
    }

    /// Switches the list's table to keep a selected row selected; returns whether it found the table.
    @discardableResult
    func apply() -> Bool {
        guard let table = KeepListSelection.table(near: self) else {
            return false
        }
        table.allowsEmptySelection = false
        return true
    }
}
