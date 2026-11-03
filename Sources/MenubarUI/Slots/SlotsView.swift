import MenubarCore
import SwiftUI

/// The Slots section (SLOT-02, SLOT-03, SLOT-09): a roadmap of the release slots with today, then each slot with the
/// countdown to its next date, its dates as steps, and its work items in columns with their merge requests, builds and
/// flags. It uses the whole width, as far as the Content Width setting allows. A click on an item shows its detail,
/// Work Items' own, beside the list. It reads the plan from the app, refreshed every minute.
public struct SlotsView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    /// the chips' ids (SLOT-07), comma-separated, kept across sections and launches; the old single id reads too, and a
    /// chip that is gone falls back, see `SlotChipSelection.restored`
    @AppStorage("slots.chip") private var storedChip = SlotChip.me.id
    /// which slot cards the user opened or closed (SLOT-15); the others follow the default, the current slot open
    @AppStorage("slots.expanded") private var storedExpansion = ""
    @Binding private var selection: WorkItem.ID?
    private let searchText: String

    /// - Parameters:
    ///   - selection: the selected work item, by its full reference
    ///   - searchText: the window's search text; empty shows everything
    public init(selection: Binding<WorkItem.ID?>, searchText: String) {
        _selection = selection
        self.searchText = searchText
    }

    public var body: some View {
        content
            .environment(\.slotOpenInTab) { openInTab($0) }
            .task {
                await model.slotLabels.load()
                await model.slotItems.load(slots: model.slotNamesToLoad())
            }
            .task(id: selection) {
                // A work item of someone else isn't among the loaded ones: its merge requests are asked for on selection.
                if let selection, let item = workItem(selection) {
                    await model.workItems.loadRelatedMergeRequests(of: item)
                }
            }
            // The last thing to load, at a low priority: the merge requests of the open cards' items that aren't mine.
            // The id restarts it (and cancels the run before) when the cards or the chips change; leaving the section
            // cancels it.
            .task(id: backgroundLoadKey, priority: .utility) {
                guard backgroundLoadKey.isSettled else { return }
                // Let the page draw and the first clicks happen before the requests start.
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                await model.workItems.loadRelatedMergeRequests(of: itemsOfOpenCards(), atOnce: 3)
            }
    }

    /// What the background load of the other items' merge requests depends on: whether the page has settled, and the
    /// chips and cards that decide which items show.
    private struct BackgroundLoadKey: Hashable {
        var isSettled: Bool
        var chips: String
        var expansion: String
        var searches: Bool
        var itemCount: Int
    }

    private var backgroundLoadKey: BackgroundLoadKey {
        BackgroundLoadKey(
            isSettled: model.workItems.lists != nil && !model.workItems.isLoading && !model.slotItems.isLoading
                && model.slotItems.items.count > 0,
            chips: storedChip, expansion: storedExpansion, searches: !searchText.isEmpty,
            itemCount: model.slotItems.items.count)
    }

    /// The work items of the slots whose cards are open, in the page's order: the current slot's first.
    private func itemsOfOpenCards() -> [WorkItem] {
        let chips = model.slotChips
        let plan = model.slotPlan(chips: selection(among: chips))
        let expansion = SlotExpansion(id: storedExpansion)
        let searching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        return plan.slots
            .filter { searching || expansion.isExpanded(name: $0.name.description, state: $0.state) }
            .flatMap { $0.allItems.map(\.workItem) }
    }

    /// The chips to show for the remembered ids. While the items load, the chips don't tell yet whether a squad or a
    /// team is gone, so the remembered chips stand; the ids are only written when a chip is clicked.
    private func selection(among chips: [SlotChip]) -> SlotChipSelection {
        let settled = model.workItems.lists != nil && !model.slotItems.isLoading
        return settled ? SlotChipSelection.restored(id: storedChip, among: chips) : SlotChipSelection(id: storedChip)
    }

    private var content: some View {
        let chips = model.slotChips
        let selected = selection(among: chips)
        return TimelineView(.periodic(from: .now, by: 60)) { context in
            SlotsContent(
                model: SlotsListModel(
                    plan: model.slotPlan(chips: selected, now: context.date), team: model.pipelines.project.team,
                    hasLoaded: model.workItems.lists != nil, needsToken: model.workItems.problem == .noToken(.gitLab),
                    query: searchText, labelsProblem: model.slotLabels.problem ?? model.slotItems.problem,
                    groupItems: model.slotItems.items.count, isLoadingGroup: model.slotItems.isLoading,
                    commitmentsProblem: model.slotItems.commitmentsProblem),
                chips: chips, selectedChips: Binding(get: { selected }, set: { storedChip = $0.id }),
                suggestedTeams: model.slotSuggestedTeams,
                expansion: Binding(get: { SlotExpansion(id: storedExpansion) }, set: { storedExpansion = $0.id }),
                selection: $selection,
                today: context.date, actions: .live(model: model, router: router, openURL: openURL),
                knows: { workItem($0) != nil }, retry: retry
            ) { id in
                // The detail is Work Items' own, for an item the group query has and my own work items don't.
                WorkItemDetailView(selection: id, fallback: workItem(id))
            }
        }
    }

    /// The work item with the reference: one of the slot group's, else one of my own.
    private func workItem(_ id: WorkItem.ID) -> WorkItem? {
        model.slotItems.items.first { $0.id == id } ?? model.workItems.lists?.all.first { $0.id == id }
    }

    /// Opens a work item under "Opened" in the sidebar, full window, and shows it there. Not Work Items: that lists only
    /// the items assigned to me or created by me, and "Opened" takes any item. Epics have no page of that kind here.
    private func openInTab(_ id: WorkItem.ID) {
        guard let item = workItem(id), !item.isEpic, let iid = item.iid.flatMap({ Int($0) }),
            let sign = item.reference.lastIndex(of: "#")
        else { return }
        let opened = model.opened.open(
            kind: .workItem, project: String(item.reference[..<sign]), iid: iid, webURL: item.webURL)
        router.show(.opened(opened))
    }

    private func retry() {
        Task {
            await model.slotLabels.load(force: true)
            await model.slotItems.load(slots: model.slotNamesToLoad(), force: true)
        }
    }
}

/// The Slots section drawn from plain values, for the window and the gallery: the list, and the detail of the selected
/// item that `detail` makes.
struct SlotsContent<Detail: View>: View {
    let model: SlotsListModel
    var chips: [SlotChip] = []
    @Binding var selectedChips: SlotChipSelection
    /// the team value the squad labels suggest, for "Suggest Members"; empty offers none
    var suggestedTeams = ""
    /// which slot cards are open (SLOT-15)
    @Binding var expansion: SlotExpansion
    @Binding var selection: WorkItem.ID?
    let today: Date
    let actions: GitLabSectionActions
    /// whether an item with the reference exists, so a restored selection of a gone item shows no detail
    var knows: (WorkItem.ID) -> Bool = { _ in true }
    /// loads the slots again, for "Try Again"; `nil` shows no button
    var retry: (() -> Void)?
    @Environment(\.slotOpenInTab) private var openInTab
    @Environment(SettingsStore.self) private var settings: SettingsStore?
    private let detail: (WorkItem.ID) -> Detail

    init(
        model: SlotsListModel, chips: [SlotChip] = [], selectedChips: Binding<SlotChipSelection>, suggestedTeams: String = "",
        expansion: Binding<SlotExpansion> = .constant(SlotExpansion()), selection: Binding<WorkItem.ID?>, today: Date,
        actions: GitLabSectionActions, knows: @escaping (WorkItem.ID) -> Bool = { _ in true }, retry: (() -> Void)? = nil,
        @ViewBuilder detail: @escaping (WorkItem.ID) -> Detail
    ) {
        self.model = model
        self.chips = chips
        _selectedChips = selectedChips
        self.suggestedTeams = suggestedTeams
        _expansion = expansion
        _selection = selection
        self.today = today
        self.actions = actions
        self.knows = knows
        self.retry = retry
        self.detail = detail
    }

    /// the selected item, while it exists
    private var shownSelection: WorkItem.ID? {
        selection.flatMap { knows($0) ? $0 : nil }
    }

    var body: some View {
        SlotDetailSplit(
            isShown: shownSelection != nil, title: title, close: { selection = nil },
            openInTab: openInTab.flatMap { open in shownSelection.map { id in { open(id) } } },
            list: { list },
            detail: {
                if let shownSelection {
                    detail(shownSelection)
                }
            })
    }

    /// "#31 Rework the color tokens" over the detail
    private var title: String {
        guard let item = model.item(selection)?.workItem else {
            return selection.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? ""
        }
        return item.shortReference(project: model.project)
    }

    private var list: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    toolbarRow
                    if let note = model.labelsNote, model.empty == nil {
                        problemRow(note)
                    }
                    if model.empty == .notLoaded {
                        // Work Items hasn't answered yet: the roadmap and two slot cards as bars.
                        SlotsSkeleton()
                    }
                    if model.empty == nil, model.slots.contains(where: { $0.dates != nil }) {
                        SlotRoadmap(slots: model.slots.filter { $0.dates != nil }, today: today) { name in
                            // The card a click on the roadmap goes to opens, so there is something to see.
                            if let slot = model.slots.first(where: { $0.name == name }) {
                                setExpanded(slot, true)
                            }
                            withAnimation(.smooth) { scroller.scrollTo(name, anchor: .top) }
                        }
                        .padding(.bottom, 4)
                    }
                    ForEach(model.slots) { slot in
                        SlotCard(
                            slot: slot, today: today, project: model.project, statusPrefix: model.statusPrefix,
                            typePrefix: model.typePrefix, selection: selection,
                            select: { selection = $0 }, actions: actions,
                            isExpanded: isExpanded(slot), setExpanded: { setExpanded(slot, $0) }
                        )
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
                .pageContentWidth()
            }
        }
        .overlay {
            if let empty = model.empty {
                emptyView(empty)
            }
        }
        // An item that is selected, from a click or from "Show in Slots", has its card open.
        .onChange(of: selection, initial: true) {
            if let id = selection, let slot = model.slots.first(where: { $0.allItems.contains { $0.id == id } }),
                !isExpanded(slot)
            {
                setExpanded(slot, true)
            }
        }
    }

    /// Whether a slot's card is open: the user's choice, else the default; every card while the search has a text, so the
    /// matching items show.
    private func isExpanded(_ slot: SlotSummary) -> Bool {
        model.isSearching || expansion.isExpanded(name: slot.name.description, state: slot.state)
    }

    private func setExpanded(_ slot: SlotSummary, _ open: Bool) {
        withAnimation(.smooth(duration: 0.2)) {
            expansion = expansion.setting(open, name: slot.name.description, state: slot.state)
        }
    }

    /// the chips, and the planning tool's page as a link at the far end
    @ViewBuilder
    private var toolbarRow: some View {
        let showsChips = !chips.isEmpty && model.empty != .noPrefix
        let planning = model.empty == nil ? model.planningURL : nil
        if showsChips || planning != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 12) {
                    if showsChips {
                        SlotChipBar(chips: chips, selection: $selectedChips, isLoading: model.isLoadingGroup)
                    }
                    Spacer(minLength: 0)
                    if let planning {
                        Button("Open Slot Planning in the Browser") { actions.open(planning) }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
                if showsChips, chips.contains(where: { if case .squad = $0 { true } else { false } }) {
                    SlotSquadHint(suggestion: suggestedTeams)
                }
            }
        }
    }

    private func problemRow(_ note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(verbatim: note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let retry {
                Button("Try Again", action: retry)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footnote: String {
        var text = model.groupItems > 0
            ? "The slots are every slot label GitLab has. The items in them are the slot group's \(model.groupItems) issues of the shown slots, by their scheduled slot, and your work items; merge requests and builds only for yours. Progress and load count done items too, as the team's planning tool does."
            : "The slots are every slot label GitLab has. The work items in them are the ones Work Items loads, so your own by its filter, with the builds the app watches."
        if model.withoutSlot > 0 {
            text += " \(model.withoutSlot) without a slot label aren't shown."
        }
        if let note = model.commitmentsNote {
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
                // The slot label prefixes live in Settings → Team, Slot Planning (the scheduled slot) and Slot Schedule.
                Button("Slot Settings…") {
                    settings?.reveal(.slotPlanning)
                    actions.openSettings(.team)
                }
            }
        case .findsNothing(let text):
            ContentUnavailableView.search(text: text)
        }
    }
}

// MARK: - A slot

/// One slot: its header, always shown, and when it is open its dates as steps and its work items in columns.
struct SlotCard: View {
    let slot: SlotSummary
    let today: Date
    let project: String
    var statusPrefix = ""
    var typePrefix = ""
    var selection: WorkItem.ID?
    var select: (WorkItem.ID) -> Void = { _ in }
    let actions: GitLabSectionActions
    /// whether the card is open (SLOT-15)
    var isExpanded = true
    /// opens or closes the card
    var setExpanded: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlotHeader(slot: slot, isExpanded: isExpanded, setExpanded: setExpanded)
            if isExpanded {
                content
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if slot.state == .current {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var content: some View {
        // No items at all: the dates first, then the quiet note; else the summary on top.
        let isEmpty = slot.allItems.isEmpty && slot.problemCount == 0
        return VStack(alignment: .leading, spacing: 12) {
            if !isEmpty {
                Text(verbatim: summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let dates = slot.dates {
                // The dates come from the slot schedule (Settings, opened from the toolbar's Slots Settings).
                SlotMilestoneRow(dates: dates, today: today, tint: slot.state == .overdue ? .orange : .accentColor)
            }
            if isEmpty {
                Text(verbatim: slot.progressText)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            if !slot.items.isEmpty || !slot.planned.isEmpty {
                Divider()
                // The columns when the card is wide enough for them, else the facts under each title.
                ViewThatFits(in: .horizontal) {
                    table(.regular)
                    table(.compact)
                }
                // The rows have their own padding; the card's is trimmed so their highlight reaches near its edge.
                .padding(.horizontal, -6)
            }
        }
    }

    private func table(_ layout: SlotRowLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The commitments first, the tree's top, each with its items here by epic; then the rest.
            ForEach(slot.commitments) { commitment in
                SlotCommitmentSection(commitment: commitment, actions: actions)
                ForEach(commitment.groups) { group in
                    SlotEpicSection(
                        group: group, project: project, statusPrefix: statusPrefix, typePrefix: typePrefix, layout: layout,
                        selection: selection, select: select, actions: actions
                    )
                    .padding(.leading, 14)
                }
            }
            if !slot.commitments.isEmpty, !slot.otherGroups.isEmpty {
                Text("Not in a commitment")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 14)
            }
            ForEach(slot.otherGroups) { group in
                SlotEpicSection(
                    group: group, project: project, statusPrefix: statusPrefix, typePrefix: typePrefix, layout: layout,
                    selection: selection, select: select, actions: actions)
            }
        }
    }

    private var summary: String {
        var parts = [slot.progressText]
        if slot.points > 0 {
            parts.append("\(Int((slot.progress * 100).rounded())) % by weight")
        }
        if slot.state == .overdue {
            parts.append("\(slot.openItems.count) still open")
        }
        if slot.uncommittedCount > 0 {
            parts.append("\(slot.uncommittedCount) planned")
        }
        if slot.flagCount > 0 {
            parts.append("\(slot.flagCount) flagged")
        }
        if slot.problemCount > 0 {
            parts.append(slot.problemCount == 1 ? "1 problem" : "\(slot.problemCount) problems")
        }
        return parts.joined(separator: " · ")
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
