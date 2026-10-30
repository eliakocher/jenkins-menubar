import MenubarCore
import SwiftUI

/// The Slots section (SLOT-02, SLOT-03): each release slot with its dates on a timeline with today, the countdown to its
/// next date, and its committed work items with their merge requests, builds and flags. It reads the plan from the app,
/// refreshed every minute, and fills the window like Activity does.
public struct SlotsView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    private let searchText: String

    /// - Parameter searchText: the window's search text; empty shows everything
    public init(searchText: String) {
        self.searchText = searchText
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            SlotsContent(
                model: SlotsListModel(
                    plan: model.slotPlan(now: context.date), team: model.pipelines.project.team,
                    hasLoaded: model.workItems.lists != nil, needsToken: model.workItems.problem == .noToken(.gitLab),
                    query: searchText),
                today: context.date, actions: .live(model: model, router: router, openURL: openURL))
        }
    }
}

/// The Slots section drawn from plain values, for the window and the gallery.
struct SlotsContent: View {
    let model: SlotsListModel
    let today: Date
    let actions: GitLabSectionActions

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let url = model.planningURL, model.empty == nil {
                    Button("Open Slot Planning") { actions.open(url) }
                        .buttonStyle(.link)
                }
                ForEach(model.slots) { slot in
                    SlotCard(slot: slot, today: today, project: model.project, actions: actions)
                }
                if model.empty == nil {
                    Text(verbatim: footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if let empty = model.empty {
                emptyView(empty)
            }
        }
    }

    private var footnote: String {
        var text = "Slots show the work items Work Items loads, so your own by its filter, and the builds the app watches."
        if model.withoutSlot > 0 {
            text += " \(model.withoutSlot) without a slot label aren't shown."
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
            ContentUnavailableView {
                Label("Loading Work Items", systemImage: "calendar.badge.clock")
            } description: {
                Text("Slots appear once GitLab has answered.")
            }
        case .noSlots:
            ContentUnavailableView {
                Label("No Slots", systemImage: "calendar.badge.clock")
            } description: {
                Text("None of the loaded work items has a slot label like \(Text(verbatim: "slot::2026.51")).")
            } actions: {
                Button("Filters…") { actions.openSettings(.gitLab) }
            }
        case .findsNothing(let text):
            ContentUnavailableView.search(text: text)
        }
    }
}

// MARK: - A slot

/// One slot: its label, state and countdown, the timeline, the dates and the committed work items.
struct SlotCard: View {
    let slot: SlotSummary
    let today: Date
    let project: String
    let actions: GitLabSectionActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            SlotTimeline(dates: slot.dates, today: today)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(slot.countdown)
            datesLine
            if slot.items.isEmpty {
                Text(verbatim: "No committed work items loaded")
                    .foregroundStyle(.secondary)
            } else {
                Divider()
                ForEach(slot.items) { item in
                    SlotItemRow(item: item, project: project, actions: actions)
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

    private var datesLine: some View {
        let style = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        return Text(
            verbatim: SlotDates.Milestone.allCases.sorted { slot.dates.date(of: $0) < slot.dates.date(of: $1) }
                .map { "\($0.title) \(slot.dates.date(of: $0).formatted(style))" }.joined(separator: " · ")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// The slot's dates on a line: a dot for each, today as a marker with its word above.
struct SlotTimeline: View {
    let dates: SlotDates
    let today: Date

    private static let height: CGFloat = 34

    var body: some View {
        GeometryReader { proxy in
            track(width: proxy.size.width)
        }
        .frame(height: Self.height)
    }

    private func track(width: CGFloat) -> some View {
        let range = self.range
        func x(_ date: Date) -> CGFloat {
            CGFloat(date.timeIntervalSince(range.lowerBound) / range.upperBound.timeIntervalSince(range.lowerBound)) * width
        }
        return ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: width, height: 4)
                    .offset(y: 24)
                Capsule()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: max(0, min(width, x(today))), height: 4)
                    .offset(y: 24)
                ForEach(SlotDates.Milestone.allCases, id: \.self) { milestone in
                    let passed = dates.date(of: milestone) < today
                    Circle()
                        .fill(passed ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                        .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 1.5) }
                        .frame(width: milestone == .release ? 12 : 9, height: milestone == .release ? 12 : 9)
                        .offset(x: x(dates.date(of: milestone)) - 5, y: milestone == .release ? 22 : 23)
                        .help("\(milestone.title) \(dates.date(of: milestone).formatted(.dateTime.day().month(.abbreviated)))")
                }
                Text("Today")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
                    .position(x: min(max(x(today), 18), max(18, width - 18)), y: 7)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 14)
                    .offset(x: x(today) - 1, y: 16)
        }
    }

    /// the days the timeline spans: the dates and today, with a day of room on each side
    private var range: ClosedRange<Date> {
        let all = [dates.earlyAccess, dates.codeFreeze, dates.release, today]
        let day: TimeInterval = 86400
        return (all.min()!.addingTimeInterval(-day))...(all.max()!.addingTimeInterval(day))
    }
}

// MARK: - A work item

/// One committed work item: its state, title, merge requests with their builds, and its flags.
struct SlotItemRow: View {
    let item: SlotItem
    let project: String
    let actions: GitLabSectionActions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: stateSymbol)
                .foregroundStyle(item.isDone ? Color.green : item.isInProgress ? Color.accentColor : .secondary)
                .frame(width: 18)
                .help(item.isDone ? "Done" : item.isInProgress ? "In progress" : "Open")
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    actions.open(item.workItem.webURL)
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
        }
        .accessibilityElement(children: .contain)
    }

    private var stateSymbol: String {
        item.isDone ? "checkmark.circle.fill" : item.isInProgress ? "circle.lefthalf.filled" : "circle"
    }

    @ViewBuilder
    private var mergeRequests: some View {
        if item.mergeRequests.isEmpty {
            if item.mergeRequestsLoaded, !item.workItem.isEpic {
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
            actions.open(mergeRequest.mergeRequest.webURL)
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
            Button(flag.fixTitle) { actions.open(flag.fixURL) }
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
