import MenubarCore
import SwiftUI

/// The Work Items section's detail column (Task 5.4, `docs/design/work-items.md`; Task 7.0): the selected work item's
/// header with its state, slot, people, chips and labels, then its merge requests with their builds, its slot's dates,
/// Claude and the description; blank without one, or when it left the list.
///
/// It looks the item, its related MRs, their builds and the Merge Requests store's MRs up in memory; selecting asks only
/// for the description, once per update of the item (WIN-02). The ages refresh every 10 s.
public struct WorkItemDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    private let selection: WorkItem.ID?

    /// - Parameter selection: the selected work item, by its full reference
    public init(selection: WorkItem.ID?) {
        self.selection = selection
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            WorkItemDetailContent(model: detail(at: context.date), actions: .live(model: model, router: router, openURL: openURL))
        }
    }
}

extension WorkItemDetailView {
    /// The selected work item's detail with its merge requests' builds and its flags (SLOT-03), and the easter egg line
    /// under its last update on the item's birthday.
    private func detail(at date: Date) -> WorkItemDetailModel? {
        let data = WorkItemsData(model, now: date)
        let item = data.lists?.all.first { $0.id == selection }
        var detail = WorkItemDetailModel(data, selection: selection, reality: item.map { model.slotItem(of: $0, now: date) })
        if model.pipelines.preferences.easterEggs, let item = detail?.workItem {
            detail?.eggLine = EggRules.birthday(reference: data.shortReference(of: item), updatedAt: item.updatedAt, now: date)
        }
        return detail
    }
}

/// The detail drawn from plain values, for the window and the gallery: a scrolling page in the merge request detail's
/// language. On top the header: the state badge, the project and the number, the type and the slot pill; the title; the
/// author and the assignees; a strip of chips for the slot's next date, the flags, the merge requests and their builds,
/// each jumping to its card or opening its page; the labels, quiet. Below, the cards in one column, or two when wide:
/// Merge Requests, Slot and Claude; then the description and the discussion. "Open in GitLab" is in the toolbar, the rest in the ⋯ menu.
struct WorkItemDetailContent: View {
    let model: WorkItemDetailModel?
    let actions: GitLabSectionActions

    @Environment(AppModel.self) private var appModel: AppModel?

    /// the cards the chips jump to
    private enum Card: Hashable {
        case mergeRequests
        case slot
    }

    /// the most merge requests the header names as chips; the card lists them all
    private static let chipLimit = 3

    var body: some View {
        if let model {
            DetailPage(id: model.workItem.id) { proxy in
                header(model) { card in
                    withAnimation(.snappy) { proxy.scrollTo(card, anchor: .top) }
                }
                // Compact fact cards in the columns; the tall ones below, full width: Description, Claude, Discussion.
                CardColumnsLayout {
                    // What the work really is: the merge requests that mention the item and their builds (WI-05, SLOT-03).
                    WorkItemMergeRequestsCard(model: model, actions: actions)
                        .id(Card.mergeRequests)
                    if let slot = model.slot {
                        WorkItemSlotCard(slot: slot, actions: actions)
                            .id(Card.slot)
                    }
                    // The item's own text, loaded on selection (WIN-02).
                    DescriptionSection(source: DescriptionSource(model.workItem), inCard: true)
                    // Ask Claude and Open in Claude Code, while the Claude features are on (AI-05, AI-08).
                    if showsClaude(model) {
                        WorkItemClaudeCard(workItem: model.workItem)
                    }
                    // The comments, in the merge request's thread look, loaded on selection too (WIN-02).
                    WorkItemDiscussionCard(source: DescriptionSource(model.workItem), actions: actions)
                }
            }
            .detailPrimaryAction("Open in GitLab", help: model.openTitle) { actions.open(model.workItem.webURL) }
        } else {
            // Blank without a selection: nothing says "select something" next to a list that may have nothing to select.
            Color.clear
        }
    }

    /// Whether the Claude card shows: while the Claude features are on, and not for an epic (AI-05).
    private func showsClaude(_ model: WorkItemDetailModel) -> Bool {
        appModel?.ai.isOffered == true && !model.workItem.isEpic
    }

    // MARK: The header

    private func header(_ model: WorkItemDetailModel, jump: @escaping (Card) -> Void) -> some View {
        let item = model.workItem
        return DetailHeader(title: item.displayTitle, titleHelp: item.displayTitle == item.title ? nil : item.title) {
            StatusBadge(
                text: model.state, symbol: item.state == .opened ? "circle.dotted" : "checkmark.circle.fill",
                tint: item.state == .opened ? MergeRequestStatus.Color.green.swiftUI : MergeRequestStatus.Color.blue.swiftUI)
            Text(verbatim: "\(model.projectName) \(item.isEpic ? "&" : "#")\(item.iid ?? "") · \(model.type)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
                .help(item.reference)
            if let slot = model.slotLabel {
                LabelPill(label: slot, style: .value)
            }
        } menu: {
            moreMenu(model)
        } byline: {
            byline(model)
        } chips: {
            chips(model, jump: jump)
        } footer: {
            if !model.labels.isEmpty {
                // Every label, scoped ones whole (WI-04), small: they describe the item, the chips say what to do.
                PillFlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(model.labels) { LabelPill(label: $0, small: true) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
        }
    }

    /// "Sam Lee · updated 5m ago · Assigned to Alex Doe and Jane Kim", wrapping between the parts when narrow; the egg line
    /// under it.
    @ViewBuilder
    private func byline(_ model: WorkItemDetailModel) -> some View {
        PillFlowLayout(spacing: 14, lineSpacing: 6) {
            HStack(spacing: 6) {
                if let author = model.author {
                    InitialsAvatar(name: author.name, username: author.username, size: 18)
                    Text(verbatim: "\(author.displayName) · updated \(model.updated)")
                } else {
                    Text(verbatim: "Updated \(model.updated)")
                }
            }
            // The flow layout proposes less than the natural width, so each part keeps its own and wraps whole.
            .fixedSize()
            if !model.assignees.isEmpty {
                HStack(spacing: 6) {
                    Text("Assigned to")
                    PeopleLine(people: model.assignees)
                }
                .fixedSize()
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        if let eggLine = model.eggLine {
            Text(verbatim: eggLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// The slot's next date, the flags, the merge requests and their builds; or why there are none.
    @ViewBuilder
    private func chips(_ model: WorkItemDetailModel, jump: @escaping (Card) -> Void) -> some View {
        if let slot = model.slot {
            DetailChip(
                symbol: slot.isOverdue ? "calendar.badge.exclamationmark" : "calendar",
                tint: slot.isOverdue ? MergeRequestStatus.Color.orange.swiftUI : .accentColor, text: slot.countdown,
                help: "Show the slot's dates"
            ) {
                jump(.slot)
            }
        }
        ForEach(model.flags) { flag in
            DetailChip(symbol: flag.kind.symbol, tint: flag.kind.tint, text: flag.kind.text, help: flag.fixTitle) {
                actions.follow(flag.fixURL)
            }
        }
        switch model.related {
        case .rows:
            let counted = model.countedMergeRequests
            ForEach(counted.prefix(Self.chipLimit)) { row in
                mergeRequestChip(row)
                if let build = row.build {
                    buildChip(build, of: row, jump: jump)
                }
            }
            if counted.count > Self.chipLimit {
                DetailChip(symbol: nil, text: "\(counted.count - Self.chipLimit) more", help: "Show the merge requests") {
                    jump(.mergeRequests)
                }
            } else if counted.isEmpty {
                // Only closed or ignored ones: the card lists them.
                DetailChip(symbol: "circle.dashed", text: "No open or merged MR", help: "Show the merge requests") {
                    jump(.mergeRequests)
                }
            }
        case .loading:
            SkeletonBlock(width: 78, height: 24)
                .skeletonShimmer(announces: false)
        case .none, .unknown, .epic:
            // The card says why, right below.
            EmptyView()
        }
    }

    /// "!14 open" in its state's color; shows it in Merge Requests while that list has it, else opens it in GitLab.
    private func mergeRequestChip(_ row: RelatedMergeRequestRow) -> some View {
        let short = row.reference.components(separatedBy: " · ").first ?? row.reference
        let word = row.mergeRequest.state == .opened ? "open" : row.mergeRequest.state.rawValue.lowercased()
        return DetailChip(
            symbol: row.symbol, tint: row.tint,
            help: row.showsInMergeRequests ? "Show in Merge Requests" : row.openTitle,
            action: {
                if row.showsInMergeRequests { actions.showInMergeRequests(row.id) } else { actions.follow(row.id) }
            }
        ) {
            HStack(spacing: 4) {
                Text(verbatim: short)
                Text(verbatim: word)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            if row.showsInMergeRequests {
                Button("Show Merge Request \(short)") { actions.showInMergeRequests(row.id) }
            } else {
                Button("Show Merge Request \(short)") { actions.follow(row.id) }
            }
            Button("Open in GitLab") { actions.open(row.id) }
            Divider()
            Button("Copy Link") { actions.copy(row.id) }
        }
    }

    /// "Build #212 passed" in its state's color; shows the build, or jumps to the card for a GitLab pipeline without a page.
    private func buildChip(_ build: BuildReality, of row: RelatedMergeRequestRow, jump: @escaping (Card) -> Void) -> some View {
        DetailChip(
            symbol: build.signal.symbol, tint: build.signal.tint,
            text: "\(build.label.map { "Build \($0)" } ?? "Pipeline") \(build.signal.word)",
            help: build.url == nil ? "Show the merge requests" : "Show the build"
        ) {
            if let url = build.url { actions.follow(url) } else { jump(.mergeRequests) }
        }
        .contextMenu {
            if let url = build.url {
                ItemLinkMenuItems(showTitle: "Show Build", openTitle: "Open Build in Jenkins", url: url, actions: actions.itemLinks)
            }
        }
    }

    /// The item's links and the follow-up (NEW-04).
    @ViewBuilder
    private func moreMenu(_ model: WorkItemDetailModel) -> some View {
        Button("Open in GitLab") { actions.open(model.workItem.webURL) }
        if model.slot != nil {
            Button("Show in Slots") { actions.showSection(.slots) }
        }
        Divider()
        Button("Copy Link") { actions.copy(model.workItem.webURL) }
        // GitLab's new issue page, prefilled with this item's link and related to it (NEW-04).
        if let newWorkItem = actions.newWorkItem {
            Button("New Follow-Up Item") { newWorkItem(.followUpOfWorkItem(model.workItem)) }
        }
    }
}

// MARK: - Merge Requests

/// The merge requests that mention the item (WI-05) with their builds (SLOT-03): the flags first, each with its fix;
/// then one row per merge request, open first, the ignored ones greyed last; the notes under them (WIN-02).
private struct WorkItemMergeRequestsCard: View {
    let model: WorkItemDetailModel
    let actions: GitLabSectionActions

    var body: some View {
        DetailCard("Merge Requests", symbol: "arrow.triangle.pull") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.flags) { flag in
                    FlagCallout(flag: flag) { actions.follow(flag.fixURL) }
                }
                content
                if !model.relatedFooters.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.relatedFooters, id: \.self) { Text(verbatim: $0) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } accessory: {
            let counted = model.countedMergeRequests
            if !counted.isEmpty {
                let open = counted.filter { $0.mergeRequest.state == .opened }.count
                CountBadge(
                    text: open > 0 ? "\(open) open" : "\(counted.count) merged",
                    tint: open > 0 ? MergeRequestStatus.Color.green.swiftUI : .purple)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.related {
        case .rows(let rows):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { RelatedMergeRequestRowView(row: $0, actions: actions) }
            }
            .padding(.horizontal, -6)
        case .none:
            note(WorkItemDetailModel.noMergeRequests)
        case .loading:
            // The rows still to come, as bars of about a row's height.
            SkeletonRows(count: 2, leading: .symbol(column: SectionRowMetrics.symbolColumn))
        case .unknown:
            note(WorkItemDetailModel.mergeRequestsUnknown)
        case .epic:
            note(WorkItemDetailModel.epicNote)
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A flag on a faint fill of its color: its symbol, its words and its fix as a link.
private struct FlagCallout: View {
    let flag: SlotFlag
    let fix: () -> Void

    var body: some View {
        let tint = flag.kind.tint
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: flag.kind.symbol)
                .foregroundStyle(tint)
            Text(verbatim: flag.kind.text)
                .fontWeight(.medium)
            Spacer(minLength: 8)
            Button(flag.fixTitle, action: fix)
                .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
        }
    }
}

/// A related merge request: its state's symbol, the title wrapping, "!14 · open", and its build as a small badge that
/// opens it; greyed when its title has Team's ignored prefix (WI-05); a trailing "Show in Merge Requests" while the Merge
/// Requests store has it. A click opens it in GitLab, and the row lights up on hover.
private struct RelatedMergeRequestRowView: View {
    let row: RelatedMergeRequestRow
    let actions: GitLabSectionActions

    @ViewState private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button { actions.follow(row.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: row.symbol)
                        .foregroundStyle(row.isIgnored ? AnyShapeStyle(.tertiary) : AnyShapeStyle(row.tint))
                        .frame(width: SectionRowMetrics.symbolColumn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.mergeRequest.title)
                            .foregroundStyle(row.isIgnored ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: row.reference)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(row.openTitle)
            if let build = row.build {
                BuildBadge(build: build) { actions.follow($0) }
            }
            if row.showsInMergeRequests {
                Button("Show in Merge Requests") { actions.showInMergeRequests(row.id) }
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.fill.quaternary.opacity(isHovered ? 1 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovered = $0 }
        .contextMenu {
            if row.showsInMergeRequests {
                Button("Show in Merge Requests") { actions.showInMergeRequests(row.id) }
                Divider()
            }
            Button(row.openTitle) { actions.follow(row.id) }
            if let url = row.build?.url {
                Button("Show Build") { actions.follow(url) }
            }
            Divider()
            Button("Copy Link") { actions.copy(row.id) }
        }
    }
}

/// A merge request's build as a small capsule in its state's color: "#212"; a click opens it when it has a page.
private struct BuildBadge: View {
    let build: BuildReality
    let open: (URL) -> Void

    var body: some View {
        let tint = build.signal.tint
        let badge = HStack(spacing: 3) {
            Image(systemName: build.signal.symbol)
            Text(verbatim: build.label ?? "Pipeline")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .fixedSize()
        let help = "\(build.label.map { "Build \($0)" } ?? "Pipeline") \(build.signal.word)"
        if let url = build.url {
            Button { open(url) } label: { badge }
                .buttonStyle(.plain)
                .help("\(help): show the build")
        } else {
            badge
                .help(help)
        }
    }
}

// MARK: - Slot

/// The slot the item is planned for: its countdown and its three dates as steps (SLOT-01, SLOT-02), with "Show in
/// Slots".
private struct WorkItemSlotCard: View {
    let slot: WorkItemDetailModel.Slot
    let actions: GitLabSectionActions

    var body: some View {
        let tint = slot.isOverdue ? MergeRequestStatus.Color.orange.swiftUI : Color.accentColor
        DetailCard("Slot \(slot.name.description)", symbol: "calendar") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Text(verbatim: slot.countdown)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint)
                    if slot.isOverdue {
                        CountBadge(text: "Overdue", tint: tint)
                    }
                }
                SlotMilestoneRow(dates: slot.dates, today: slot.today, tint: tint)
            }
        } accessory: {
            Button("Show in Slots") { actions.showSection(.slots) }
                .buttonStyle(.link)
                .font(.callout)
        }
    }
}

// MARK: - Claude

/// Claude about the work item, while the Claude features are on: a field to ask about it (AI-08), whose answer can be
/// followed up, and Open in Claude Code in the checkout on the item's branch (AI-05); nothing for an epic.
private struct WorkItemClaudeCard: View {
    let workItem: WorkItem

    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model, model.ai.isOffered, !workItem.isEpic {
            let subject = AISubject.workItem(workItem.reference)
            DetailCard("Claude", symbol: "sparkles", width: .fullWidth) {
                InlineClaudeChat(
                    subject: subject, item: .workItem(workItem), base: workItem.webURL, placeholder: "Ask Claude about this item…",
                    ask: { question, picked in
                        let description = model.descriptions.description(of: DescriptionSource(workItem)).text
                        Task {
                            await model.ai.ask(question, about: workItem, description: description, model: picked)
                        }
                    }
                ) { _ in
                    // The user (2026-10-30): no separate Open in Claude Code here; the chat's Continue in Claude Code
                    // covers it after an answer.
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - Colors

extension RelatedMergeRequestRow {
    /// the state's color: open green, merged purple, the rest grey
    var tint: Color {
        switch mergeRequest.state {
        case .opened: MergeRequestStatus.Color.green.swiftUI
        case .merged: .purple
        default: .secondary
        }
    }
}

extension SlotFlag.Kind {
    /// the flag's color: ready to verify green, a red build red, no merge request orange
    var tint: Color {
        switch self {
        case .readyToVerify: MergeRequestStatus.Color.green.swiftUI
        case .redPipeline, .doneWithRedBuild: MergeRequestStatus.Color.red.swiftUI
        case .noMergeRequest: MergeRequestStatus.Color.orange.swiftUI
        }
    }
}

extension BuildSignal {
    /// the symbol, as the build badges have it
    var symbol: String {
        switch self {
        case .green: "checkmark.circle.fill"
        case .red: "xmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    /// GitLab's colors: green passed, red failed, blue running
    var tint: Color {
        switch self {
        case .green: MergeRequestStatus.Color.green.swiftUI
        case .red: MergeRequestStatus.Color.red.swiftUI
        case .running: MergeRequestStatus.Color.blue.swiftUI
        }
    }

    /// "passed", "failed", "running"
    var word: String {
        switch self {
        case .green: "passed"
        case .red: "failed"
        case .running: "running"
        }
    }
}
