import AppKit
import SwiftUI
import Testing

@testable import MenubarUI

/// A click on a list's empty space keeps the selection (the rule and its binding), and the selection follows a row that
/// leaves the list. Real clicks can't be sent here: the table's own behavior is checked on an offscreen window.
@MainActor
@Suite("KeepListSelection")
struct KeepListSelectionTests {
    @Test("WIN-02 the list's write of nil keeps the selection, a row replaces it")
    func binding() {
        var stored: String? = "a"
        let binding = Binding(get: { stored }, set: { stored = $0 }).keepingSelection()
        binding.wrappedValue = nil
        #expect(stored == "a")
        #expect(binding.wrappedValue == "a")
        binding.wrappedValue = "b"
        #expect(stored == "b")
        // Code that clears on purpose writes the underlying value, which the binding shows.
        stored = nil
        #expect(binding.wrappedValue == nil)
        binding.wrappedValue = nil
        #expect(stored == nil)
        #expect(KeepListSelection.resolved(proposed: nil, current: 3) == 3)
        #expect(KeepListSelection.resolved(proposed: 4, current: 3) == 4)
    }

    @Test(
        "WIN-02 a selected row that leaves the list passes the selection to the next row, else the previous one",
        arguments: [
            // still there: kept
            (["a", "b", "c"], ["a", "b", "c"], "b", "b"),
            (["a", "b", "c"], ["a", "c"], "a", "a"),
            // gone: the row that moved into its place
            (["a", "b", "c", "d"], ["a", "c", "d"], "b", "c"),
            (["a", "b", "c", "d"], ["a", "d"], "b", "d"),
            // gone at the end: the one before it
            (["a", "b", "c"], ["a", "b"], "c", "b"),
            (["a", "b", "c", "d"], ["a", "b"], "c", "b"),
            // never in the list (opened from another section, restored): kept
            (["a", "b"], ["a"], "x", "x"),
            // an emptied list (a reload, a failed check): kept, the detail is blank until the row is back
            (["a", "b"], [], "a", "a"),
        ])
    func neighbour(old: [String], new: [String], selected: String, expected: String) {
        #expect(KeepListSelection.kept(selected, from: old, to: new) == expected)
    }

    @Test("WIN-02 a table behind the anchor keeps its row on a deselect, a list without it doesn't, and code can still clear")
    func tableKeepsRow() async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: TwoLists().frame(width: 600, height: 300))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(500))
        let tables = Self.tables(in: host)
        #expect(tables.count == 2)
        // The anchor found its list's table on its own, a turn of the run loop after the list was built: the first
        // list (left) has it, not the other one.
        let (kept, free) = (tables[0], tables[1])
        #expect(kept.allowsEmptySelection == false)
        #expect(free.allowsEmptySelection == true)
        kept.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        free.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        kept.deselectAll(nil)
        free.deselectAll(nil)
        #expect(kept.selectedRowIndexes == IndexSet(integer: 1))
        #expect(free.selectedRowIndexes.isEmpty)
        // Cleared by code, as when Back returns to a state without a selection.
        kept.selectRowIndexes([], byExtendingSelection: false)
        #expect(kept.selectedRowIndexes.isEmpty)
        window.orderOut(nil)
    }

    private struct TwoLists: View {
        var body: some View {
            HStack(spacing: 0) {
                List(selection: .constant(Int?.some(2))) {
                    ForEach(1...5, id: \.self) { Text("Row \($0)").tag($0) }
                }
                .keepsSelection()
                List(selection: .constant(Int?.some(2))) {
                    ForEach(1...5, id: \.self) { Text("Row \($0)").tag($0) }
                }
            }
        }
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView {
            return [table]
        }
        return view.subviews.flatMap { tables(in: $0) }
    }
}
