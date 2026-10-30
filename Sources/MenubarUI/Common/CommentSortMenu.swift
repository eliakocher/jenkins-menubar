import MenubarCore
import SwiftUI

/// The sort menu in the Discussion card's header, the same in the merge request's and the work item's (MR-07, WIN-02):
/// Newest First or Oldest First by each thread's last activity, and "Open First", which puts the open threads before the
/// resolved ones. The choice is remembered per user; the cards read it with ``DiscussionOrder``.
struct CommentSortMenu: View {
    @AppStorage(CommentThreadOrder.sortKey) private var sort: CommentThreadSort = .oldestFirst
    @AppStorage(CommentThreadOrder.openFirstKey) private var openFirst = true

    var body: some View {
        Menu {
            Picker("Sort Threads", selection: $sort) {
                ForEach(CommentThreadSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Open First", isOn: $openFirst)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort the threads: \(sort.title)\(openFirst ? ", open first" : "")")
        .accessibilityLabel("Sort Threads")
    }
}

/// The remembered order of the discussion threads: a card holds this as a property and reads `order`; it reads the same
/// preferences as ``CommentSortMenu`` writes.
struct DiscussionOrder: DynamicProperty {
    @AppStorage(CommentThreadOrder.sortKey) private var sort: CommentThreadSort = .oldestFirst
    @AppStorage(CommentThreadOrder.openFirstKey) private var openFirst = true

    var order: CommentThreadOrder { CommentThreadOrder(sort: sort, openFirst: openFirst) }
}
