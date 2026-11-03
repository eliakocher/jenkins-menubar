import MenubarCore
import SwiftUI

/// What an opened item's row in the sidebar shows besides its kind: the title as line 1 shows it, the colour of the
/// leading symbol and the chips of line 2 (WIN-06). It comes from what the store already holds, so a row asks for
/// nothing.
struct OpenedItemRowDetails: Equatable {
    /// one small chip of line 2
    enum Chip: Equatable {
        /// a work item's number, "#19162", blue
        case workItem(text: String, help: String?)
        /// a merge request's number, "!12", or "!14 +1" for a work item's several, green whatever the state
        case mergeRequest(text: String, help: String?)
        /// a build's number, "#7"
        case build(text: String)
    }

    /// the title without its leading work item number
    var title: String
    /// the leading symbol's colour; `nil` keeps the secondary style
    var symbolTint: Color?
    var chips: [Chip] = []

    /// Returns the details of an item from what is loaded of it.
    ///
    /// - Parameters:
    ///   - item: the opened item
    ///   - related: the work item's merge requests, when they were asked
    ///   - workItem: the work item as loaded, to tell its own merge requests
    ///   - build: the build as loaded
    static func make(
        item: OpenedItem, workItem: WorkItem? = nil,
        related: RelatedMergeRequestsCache.Entry? = nil, build: Build? = nil
    ) -> OpenedItemRowDetails {
        let split = OpenedItemTitle.split(item.title ?? item.fallbackTitle)
        switch item.kind {
        case .workItem:
            var chips = [Chip.workItem(text: item.shortReference, help: nil)]
            if let workItem, let related,
                let chip = WorkItemMergeRequestChip.make(
                    workItem.shownMergeRequests(from: related.mergeRequests), marker: nil, project: item.project, ignoredPrefix: "")
            {
                chips.append(.mergeRequest(text: chip.text ?? "!", help: chip.help))
            }
            return OpenedItemRowDetails(title: split.title, symbolTint: .workItemNumber, chips: chips)
        case .mergeRequest:
            var chips = [Chip.mergeRequest(text: item.shortReference, help: nil)]
            if let number = split.workItemNumber {
                chips.append(.workItem(text: "#\(number)", help: nil))
            }
            return OpenedItemRowDetails(title: split.title, symbolTint: ReferenceKind.mergeRequest.tint, chips: chips)
        case .build:
            var chips = [Chip.build(text: item.shortReference)]
            if let iid = Build.mergeRequestIID(forJob: item.job ?? "") {
                chips.append(.mergeRequest(text: "!\(iid)", help: nil))
            }
            return OpenedItemRowDetails(title: split.title, symbolTint: tint(of: build), chips: chips)
        }
    }

    /// the symbol colour of a build: its result's, blue while it runs, grey while it isn't loaded
    private static func tint(of build: Build?) -> Color {
        guard let build else {
            return .secondary
        }
        let state = BuildState(build)
        return state == .running ? MergeRequestStatus.Color.blue.swiftUI : state.color ?? .secondary
    }
}

/// Line 2 of an opened item's row: its chips, in `.caption`. A selected row draws them white (``inlineChip(tint:)`` does
/// when the menu highlight is on).
struct OpenedItemChipsLine: View {
    let chips: [OpenedItemRowDetails.Chip]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                switch chip {
                case .workItem(let text, let help):
                    WorkItemNumberChip(text: text, help: help)
                case .mergeRequest(let text, let help):
                    MergeRequestNumberChip(text: text, help: help)
                case .build(let text):
                    Text(verbatim: text)
                        .monospacedDigit()
                        .inlineChip(tint: .chipNeutral)
                }
            }
        }
        .lineLimit(1)
    }
}
