import MenubarCore
import SwiftUI

/// The work item's Discussion card (WIN-02): its comment threads in the merge request's thread look, loaded when the item
/// is selected, once per update of the item. While it loads, skeleton lines; when it fails, a quiet line with "Try
/// Again"; an item without comments shows no card. System notes ("changed the label…") are left out.
struct WorkItemDiscussionCard: View {
    let source: DescriptionSource
    let actions: GitLabSectionActions

    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.discussionFixtures) private var fixtures
    /// the item last asked for, so that a failure line or a spinner appearing for the same item doesn't ask again
    @ViewState private var asked: DescriptionSource?
    @ViewState private var showsAll = false
    private let threadOrder = DiscussionOrder()
    /// the threads the user opened, kept while the card stays on screen
    @ViewState private var expanded: Set<String> = []

    /// threads shown before "Show All (N)"
    private static let cut = 10

    var body: some View {
        let state = fixtures?[source.reference] ?? model?.itemDiscussions.state(of: source) ?? .loaded(WorkItemDiscussion())
        if let discussion = state.discussion, !discussion.threads.isEmpty {
            DetailCard("Discussion", symbol: "bubble.left.and.bubble.right", width: .fullWidth) {
                threads(discussion)
                    .task(id: source) { await load() }
            } accessory: {
                let count = discussion.commentCount
                HStack(spacing: 8) {
                    CountBadge(text: "\(count)\(discussion.hasMore ? "+" : "") \(count == 1 ? "comment" : "comments")")
                    if discussion.threads.count > 1 {
                        CommentSortMenu()
                    }
                }
            }
        } else if state.isCurrent {
            // No comments: no card.
        } else if state.failed {
            DetailCard("Discussion", symbol: "bubble.left.and.bubble.right", width: .fullWidth) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("The discussion couldn't be loaded")
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        asked = nil
                        Task { await load() }
                    }
                    .buttonStyle(.link)
                }
                .task(id: source) { await load() }
            }
        } else {
            DetailCard("Discussion", symbol: "bubble.left.and.bubble.right", width: .fullWidth) {
                // Two comments' worth of lines, in the card's own chrome.
                SkeletonLines(count: 5)
                    .task(id: source) { await load() }
            }
        }
    }

    @ViewBuilder
    private func threads(_ discussion: WorkItemDiscussion) -> some View {
        // The user's order: by last activity, open threads first or not.
        let all = threadOrder.order.ordered(discussion.threads)
        let shown = showsAll ? all : Array(all.prefix(Self.cut))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown) { thread in
                CommentThreadView(thread: thread, base: source.webURL, expanded: $expanded) { actions.open($0) }
            }
        }
        HStack(spacing: 12) {
            if all.count > Self.cut {
                Button(showsAll ? "Show Less" : "Show All (\(all.count))") {
                    withAnimation(.snappy) { showsAll.toggle() }
                }
            }
            if discussion.hasMore {
                Button("More Comments in GitLab") { actions.open(source.webURL) }
            }
        }
        .buttonStyle(.link)
    }

    /// Asks the store once per item and update.
    private func load() async {
        guard fixtures == nil, let model, asked != source else {
            return
        }
        asked = source
        await model.itemDiscussions.load(source)
    }
}

/// The discussions the gallery shows in place of the store's, by reference.
typealias DiscussionFixtures = [String: ItemDiscussionState]

private struct DiscussionFixturesKey: EnvironmentKey {
    static let defaultValue: DiscussionFixtures? = nil
}

extension EnvironmentValues {
    /// the gallery's discussions; `nil` in the app, which takes the store's
    var discussionFixtures: DiscussionFixtures? {
        get { self[DiscussionFixturesKey.self] }
        set { self[DiscussionFixturesKey.self] = newValue }
    }
}
