import MenubarCore
import SwiftUI

/// The Slots section (SLOT-02, SLOT-03): a roadmap of the release slots with today, then each slot with the countdown to
/// its next date, its dates as steps, and its committed work items with their merge requests, builds and flags. It reads the plan from the app,
/// refreshed every minute, and fills the window like Activity does.
public struct SlotsView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    @ViewState private var chip: SlotChip = .me
    private let searchText: String

    /// - Parameter searchText: the window's search text; empty shows everything
    public init(searchText: String) {
        self.searchText = searchText
    }

    public var body: some View {
        content
            .task {
                await model.slotLabels.load()
                await model.slotItems.load(slots: model.slotNamesToLoad())
            }
    }

    private var content: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            SlotsContent(
                model: SlotsListModel(
                    plan: model.slotPlan(chip: chip, now: context.date), team: model.pipelines.project.team,
                    hasLoaded: model.workItems.lists != nil, needsToken: model.workItems.problem == .noToken(.gitLab),
                    query: searchText, labelsProblem: model.slotLabels.problem ?? model.slotItems.problem,
                    groupItems: model.slotItems.items.count, isLoadingGroup: model.slotItems.isLoading),
                chips: model.slotChips, chip: $chip,
                today: context.date, actions: .live(model: model, router: router, openURL: openURL))
        }
    }
}

/// The Slots section drawn from plain values, for the window and the gallery.
struct SlotsContent: View {
    let model: SlotsListModel
    var chips: [SlotChip] = []
    @Binding var chip: SlotChip
    let today: Date
    let actions: GitLabSectionActions

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !chips.isEmpty, model.empty != .noPrefix {
                        SlotChipBar(chips: chips, chip: $chip, isLoading: model.isLoadingGroup)
                    }
                    if let url = model.planningURL, model.empty == nil {
                        Button("Open Slot Planning") { actions.open(url) }
                            .buttonStyle(.link)
                    }
                    if model.empty == .notLoaded {
                        // Work Items hasn't answered yet: the roadmap and two slot cards as bars.
                        SlotsSkeleton()
                    }
                    if model.empty == nil, !model.slots.isEmpty {
                        SlotRoadmap(slots: model.slots, today: today) { name in
                            withAnimation(.smooth) { scroller.scrollTo(name, anchor: .top) }
                        }
                        .padding(.bottom, 4)
                    }
                    ForEach(model.slots) { slot in
                        SlotCard(slot: slot, today: today, project: model.project, statusPrefix: model.statusPrefix, actions: actions)
                            .id(slot.name)
                    }
                    if model.empty == nil {
                        Text(verbatim: footnote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }
                .padding(16)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .overlay {
            if let empty = model.empty {
                emptyView(empty)
            }
        }
    }

    private var footnote: String {
        var text = model.groupItems > 0
            ? "The slots are every slot label GitLab has. The items in them are the slot group's \(model.groupItems) issues of the shown slots and your work items; merge requests and builds only for yours."
            : "The slots are every slot label GitLab has. The work items in them are the ones Work Items loads, so your own by its filter, with the builds the app watches."
        if model.withoutSlot > 0 {
            text += " \(model.withoutSlot) without a slot label aren't shown."
        }
        if let note = model.labelsNote {
            text += " \(note)."
        }
        return text
    }

    @ViewBuilder
    private func emptyView(_ empty: SlotsListModel.Empty) -> some View {
        switch empty {
        case .noPrefix:
            ContentUnavailableView {
                Label("No Slot Label Prefix", systemImage: "calendar.badge.clock")
            } description: {
                Text("Set the slot label prefix, like slot::, in Settings → Projects.")
            } actions: {
                Button("Open Settings") { actions.openSettings(.team) }
            }
        case .noToken:
            ContentUnavailableView {
                Label("GitLab Needs a Token", systemImage: "key")
            } description: {
                Text("Slots come from your work items.")
            } actions: {
                Button("Show Merge Requests") { actions.showSection(.mergeRequests) }
            }
        case .notLoaded:
            // The skeleton in the page itself.
            EmptyView()
        case .noSlots:
            ContentUnavailableView {
                Label("No Slots", systemImage: "calendar.badge.clock")
            } description: {
                Text("GitLab has no slot labels and none of the loaded work items has one like \(Text(verbatim: "slot::2026.51")).")
            } actions: {
                Button("Filters…") { actions.openSettings(.gitLab) }
            }
        case .findsNothing(let text):
            ContentUnavailableView.search(text: text)
        }
    }
}

// MARK: - A slot

/// One slot: its label, state and countdown, its three dates as steps, and the committed work items.
struct SlotCard: View {
    let slot: SlotSummary
    let today: Date
    let project: String
    var statusPrefix = ""
    let actions: GitLabSectionActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            SlotMilestoneRow(dates: slot.dates, today: today, tint: slot.state == .overdue ? .orange : .accentColor)
            SlotLoadLine(slot: slot)
            if !slot.items.isEmpty || !slot.planned.isEmpty {
                Divider()
                ForEach(slot.epicGroups) { group in
                    SlotEpicSection(group: group, project: project, statusPrefix: statusPrefix, actions: actions)
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if slot.state == .current {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                LabelPill(label: LabelPillModel(slot.label), style: .value)
                    .font(.headline)
                Text(verbatim: slot.state.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(slot.state == .current ? Color.accentColor : .secondary)
                Spacer(minLength: 8)
                Text(verbatim: slot.countdown)
                    .font(.headline)
                    .foregroundStyle(slot.state == .overdue ? .orange : .primary)
            }
            Text(verbatim: summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        var parts = [slot.progressText]
        if slot.state == .overdue {
            parts.append("\(slot.openItems.count) still open")
        }
        if slot.flagCount > 0 {
            parts.append("\(slot.flagCount) flagged")
        }
        if slot.uncommittedCount > 0 {
            parts.append("\(slot.uncommittedCount) not committed")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - A work item

/// One committed work item: its state, title, merge requests with their builds, and its flags.
struct SlotItemRow: View {
    let item: SlotItem
    let project: String
    var statusPrefix = ""
    let actions: GitLabSectionActions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: stateSymbol)
                .foregroundStyle(item.isDone ? Color.green : item.isInProgress ? Color.accentColor : .secondary)
                .frame(width: 18)
                .help(item.isDone ? "Done" : item.isInProgress ? "In progress" : "Open")
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    actions.follow(item.workItem.webURL)
                } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: item.workItem.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(verbatim: item.workItem.shortReference(project: project))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open in GitLab") { actions.open(item.workItem.webURL) }
                    Button("Copy Link") { actions.copy(item.workItem.webURL) }
                }
                mergeRequests
                ForEach(item.flags) { flag in
                    SlotFlagLine(flag: flag, actions: actions)
                }
            }
            Spacer(minLength: 0)
            SlotItemFacts(item: item, statusPrefix: statusPrefix)
        }
        .accessibilityElement(children: .contain)
    }

    private var stateSymbol: String {
        item.isDone ? "checkmark.circle.fill" : item.isInProgress ? "circle.lefthalf.filled" : "circle"
    }

    @ViewBuilder
    private var mergeRequests: some View {
        if item.mergeRequests.isEmpty {
            if item.mergeRequestsLoaded, !item.workItem.isEpic, item.isCommitted {
                Text(verbatim: "No merge request")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 10) {
                ForEach(item.mergeRequests) { mergeRequest in
                    SlotMergeRequestChip(mergeRequest: mergeRequest, project: project, actions: actions)
                }
            }
        }
    }
}

/// A merge request as "!12" with its state and its build's state.
struct SlotMergeRequestChip: View {
    let mergeRequest: SlotMergeRequest
    let project: String
    let actions: GitLabSectionActions

    var body: some View {
        Button {
            actions.follow(mergeRequest.mergeRequest.webURL)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: mergeSymbol)
                    .foregroundStyle(mergeColor)
                Text(verbatim: GitLabText.shortReference(mergeRequest.mergeRequest.reference, project: project))
                if let build = mergeRequest.build {
                    Image(systemName: BuildState(build.signal).symbol)
                        .foregroundStyle(BuildState(build.signal).color ?? .secondary)
                }
            }
            .font(.caption)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var mergeSymbol: String {
        switch mergeRequest.mergeRequest.state {
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        default: "arrow.triangle.pull"
        }
    }

    private var mergeColor: Color {
        switch mergeRequest.mergeRequest.state {
        case .merged: .purple
        case .closed: .secondary
        default: .green
        }
    }

    private var help: String {
        let state = mergeRequest.mergeRequest.state.rawValue.capitalized
        let build = mergeRequest.build.map { build in
            let name = switch build.signal {
            case .green: "green"
            case .red: "red"
            case .running: "running"
            }
            return ", build \(build.label.map { $0 + " " } ?? "")\(name)"
        }
        return "\(mergeRequest.mergeRequest.title): \(state)\(build ?? ", no build known")"
    }
}

/// A flag with its fix as a link.
struct SlotFlagLine: View {
    let flag: SlotFlag
    let actions: GitLabSectionActions

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: flag.kind.symbol)
            Text(verbatim: flag.kind.text)
            Button(flag.fixTitle) { actions.follow(flag.fixURL) }
                .buttonStyle(.link)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
    }

    private var color: Color {
        switch flag.kind {
        case .readyToVerify: .green
        case .redPipeline, .doneWithRedBuild: .red
        case .noMergeRequest: .orange
        }
    }
}

extension BuildState {
    /// The state a slot's build signal shows as.
    init(_ signal: BuildSignal) {
        switch signal {
        case .green: self = .successful
        case .red: self = .failed
        case .running: self = .running
        }
    }
}

/// The Slots page before Work Items has loaded: the roadmap's rows and two slot cards as bars, in the real ones' chrome
/// and about their size, so the page doesn't jump when the slots arrive.
struct SlotsSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The roadmap: a name and a bar per slot, starting at different dates.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 8) {
                        SkeletonBlock(width: 46, height: 8, lineHeight: 20)
                        SkeletonBlock(fraction: [0.5, 0.62, 0.4, 0.55][index], height: 6, lineHeight: 20)
                    }
                }
            }
            .skeletonShimmer()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 4)
            ForEach(0..<2, id: \.self) { index in
                slotCard(index)
            }
        }
    }

    private func slotCard(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SkeletonBlock(width: 90, height: 18)
                SkeletonBlock(width: 60, height: 8, lineHeight: 16)
                Spacer(minLength: 8)
                SkeletonBlock(width: 110, height: 10, lineHeight: 18)
            }
            SkeletonBlock(width: 230, height: 8, lineHeight: 14)
            SkeletonBlock(height: 8, lineHeight: 28)
            Divider()
            SkeletonRows(count: index == 0 ? 3 : 2, leading: .symbol(column: SectionRowMetrics.symbolColumn))
        }
        .skeletonShimmer()
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
