import AppKit
import MenubarCore
import SwiftUI

// MARK: - What a row says

/// The words and symbols of a slot item's row, from its labels (SLOT-09). Pure, so the rows and the tests read the same.
enum SlotItemText {
    /// the kind of work a row shows a symbol for
    enum Kind: Hashable {
        case bug
        case feature
        case task
        case epic
        case other

        /// the SF Symbol
        var symbol: String {
            switch self {
            case .bug: "ladybug.fill"
            case .feature: "sparkles"
            case .task: "checkmark.square"
            case .epic: "flag.fill"
            case .other: "doc.text"
            }
        }

        var tint: Color {
            switch self {
            case .bug: .red
            case .feature: .indigo
            case .epic: .purple
            case .task, .other: .secondary
            }
        }
    }

    /// Returns the value of the item's label with the prefix, like "InProgress" for `status::InProgress`, spaced as
    /// "In Progress"; `nil` without a prefix or a label.
    ///
    /// - Parameters:
    ///   - labels: the item's labels
    ///   - prefix: the label prefix from Team; empty has none
    static func value(in labels: [MenubarCore.Label], prefix: String) -> String? {
        guard !prefix.isEmpty, let label = labels.first(where: { $0.title.hasPrefix(prefix) }) else { return nil }
        let value = String(label.title.dropFirst(prefix.count))
        var spaced = ""
        for character in value {
            if character.isUppercase, let last = spaced.last, last.isLowercase {
                spaced.append(" ")
            }
            spaced.append(character)
        }
        return spaced.isEmpty ? nil : spaced
    }

    /// Returns the item's status, like "In Progress".
    static func status(of item: WorkItem, prefix: String) -> String? {
        value(in: item.labels, prefix: prefix)
    }

    /// Returns the item's kind and its name: from the type label when Team has a prefix and the item has one, else from
    /// the work item's own type.
    static func kind(of item: WorkItem, prefix: String) -> (kind: Kind, name: String) {
        if item.isEpic || item.type == .epic {
            return (.epic, "Epic")
        }
        if let value = value(in: item.labels, prefix: prefix) {
            let lowered = value.lowercased()
            if lowered.contains("bug") { return (.bug, value) }
            if lowered.contains("feature") { return (.feature, value) }
            if lowered.contains("task") { return (.task, value) }
            return (.other, value)
        }
        return item.type == .task ? (.task, "Task") : (.other, "Issue")
    }
}

// MARK: - The columns

/// How a row lays out: all the columns, or the facts folded under the title when the card is narrow (SLOT-09).
enum SlotRowLayout: Equatable {
    case regular
    case compact
}

/// The widths of the columns, shared by the rows and the header over them.
enum SlotColumns {
    static let state: CGFloat = 16
    static let type: CGFloat = 18
    static let reference: CGFloat = 74
    static let commitment: CGFloat = 84
    static let progress: CGFloat = 56
    static let status: CGFloat = 108
    static let assignees: CGFloat = 60
    static let weight: CGFloat = 42
    static let spacing: CGFloat = 10
    /// the least width the title gets before the columns give way to the compact row
    static let title: CGFloat = 280
}

/// The titles of the columns over a slot's items.
struct SlotColumnHeader: View {
    var body: some View {
        HStack(spacing: SlotColumns.spacing) {
            Color.clear.frame(width: SlotColumns.state + SlotColumns.spacing + SlotColumns.type)
            column("Item", width: SlotColumns.reference)
            Text("Title")
                .frame(minWidth: SlotColumns.title, idealWidth: SlotColumns.title, maxWidth: .infinity, alignment: .leading)
            column("Commitment", width: SlotColumns.commitment)
            column("Progress", width: SlotColumns.progress)
            column("Status", width: SlotColumns.status)
            column("Assignees", width: SlotColumns.assignees)
            column("Weight", width: SlotColumns.weight, alignment: .trailing)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .accessibilityHidden(true)
    }

    private func column(_ title: LocalizedStringKey, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(title)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }
}

// MARK: - An epic and its items

/// An epic with its items in the slot, or the items without one (SLOT-08).
struct SlotEpicSection: View {
    let group: SlotEpicGroup
    let project: String
    var statusPrefix = ""
    var typePrefix = ""
    let layout: SlotRowLayout
    let selection: WorkItem.ID?
    let select: (WorkItem.ID) -> Void
    let actions: GitLabSectionActions

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            ForEach(group.items) { item in
                SlotItemRow(
                    item: item, project: project, statusPrefix: statusPrefix, typePrefix: typePrefix, layout: layout,
                    isSelected: selection == item.id, select: { select(item.id) }, actions: actions)
            }
        }
    }

    /// The header with its progress, or without the progress text and bar when the list is narrow (the detail beside it
    /// may take all but 300 pt).
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(showsProgress: true)
            headerRow(showsProgress: false)
            if group.epic != nil, let problem = group.problem {
                // Narrower still: the epic's title, and its problem under it.
                VStack(alignment: .leading, spacing: 4) {
                    headerRow(showsProgress: false, showsProblem: false)
                    SlotProblemPill(problem: problem)
                        .padding(.leading, 20)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func headerRow(showsProgress: Bool, showsProblem: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: group.epic == nil ? "tray" : "flag.fill")
                .foregroundStyle(group.epic == nil ? Color.secondary : .purple)
                .font(.caption)
            if let epic = group.epic {
                Button {
                    actions.follow(epic.webURL)
                } label: {
                    Text(verbatim: epic.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .help("Open \(epic.reference)")
                .contextMenu {
                    Button("Open in GitLab") { actions.open(epic.webURL) }
                    Button("Copy Link") { actions.copy(epic.webURL) }
                }
            } else {
                Text("No epic")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if showsProblem, let problem = group.problem {
                SlotProblemPill(problem: problem)
            }
            Spacer(minLength: 8)
            if showsProgress {
                Text(verbatim: "\(group.items.count { $0.isDone }) of \(group.items.count) done")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                SlotProgressBar(progress: group.progress, width: 72)
                    .help(
                        "This slot's share: \(Int((group.progress * 100).rounded())) % of the \(group.points) points of its items here, Verified 100 %, in verification 75 %. Its items in other slots don't count.")
            }
        }
    }
}

// MARK: - A commitment

/// A commitment heading its items in the slot: its title, due date, how many of its items are elsewhere and this slot's
/// share of its progress (SLOT-14).
struct SlotCommitmentSection: View {
    let commitment: SlotCommitmentGroup
    let actions: GitLabSectionActions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showsMore: true)
            row(showsMore: false)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .opacity(commitment.commitment.state == .closed ? 0.55 : 1)
    }

    /// The row with the count of items elsewhere and the progress bar, or without them when the list is narrow.
    private func row(showsMore: Bool) -> some View {
        let value = commitment.commitment
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "seal.fill")
                .foregroundStyle(.teal)
                .font(.caption)
            Button {
                actions.follow(value.webURL)
            } label: {
                Text(verbatim: value.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .help("Commitment \(value.reference)")
            .contextMenu {
                Button("Open in GitLab") { actions.open(value.webURL) }
                Button("Copy Link") { actions.copy(value.webURL) }
            }
            if let due = dueText {
                Text(verbatim: due)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(.teal)
                    .background(Color.teal.opacity(0.12), in: Capsule())
                    .fixedSize()
            }
            if showsMore, commitment.elsewhere > 0 {
                Text(verbatim: commitment.elsewhere == 1 ? "1 more item in another slot" : "\(commitment.elsewhere) more items in other slots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(verbatim: "\(commitment.items.count { $0.isDone }) of \(commitment.items.count) done")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if showsMore {
                SlotProgressBar(progress: commitment.progress, width: 72)
                    .help("This slot's share: \(Int((commitment.progress * 100).rounded())) % by weight of its items here")
            }
        }
    }

    /// "Due 30 Nov", from the date a person typed
    private var dueText: String? {
        guard let text = commitment.commitment.dueDate,
            let date = try? Date(text + "T12:00:00Z", strategy: .iso8601)
        else { return nil }
        return "Due " + date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - A work item

/// One work item of a slot: its state and type, reference, title with its merge requests and flags, and its facts in
/// columns, or folded under the title when narrow. A click selects it, so its detail shows beside the list; a double
/// click opens it in a tab; ⌥-click opens it in GitLab (SLOT-09).
struct SlotItemRow: View {
    let item: SlotItem
    let project: String
    var statusPrefix = ""
    var typePrefix = ""
    let layout: SlotRowLayout
    let isSelected: Bool
    let select: () -> Void
    let actions: GitLabSectionActions
    @ViewState private var isHovered = false
    @Environment(\.slotOpenInTab) private var openInTab

    var body: some View {
        content
            .opacity(item.isDone ? 0.55 : 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { isHovered = $0 }
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.option) {
                    actions.open(item.workItem.webURL)
                } else if let openInTab, !item.workItem.isEpic, NSApp.currentEvent?.clickCount == 2 {
                    openInTab(item.id)
                } else {
                    select()
                }
            }
            .contextMenu {
                Button("Show Details", action: select)
                if let openInTab, !item.workItem.isEpic {
                    Button("Open in a Tab") { openInTab(item.id) }
                }
                Divider()
                Button("Open in GitLab") { actions.open(item.workItem.webURL) }
                Button("Copy Link") { actions.copy(item.workItem.webURL) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction(named: "Show Details", select)
    }

    private var background: Color {
        isSelected ? Color.accentColor.opacity(0.18) : isHovered ? Color.primary.opacity(0.06) : .clear
    }

    private var kind: (kind: SlotItemText.Kind, name: String) {
        SlotItemText.kind(of: item.workItem, prefix: typePrefix)
    }

    private var status: String? {
        SlotItemText.status(of: item.workItem, prefix: statusPrefix)
    }

    private var reference: String {
        item.workItem.shortReference(project: project)
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .regular: regular
        case .compact: compact
        }
    }

    // MARK: Regular

    private var regular: some View {
        HStack(alignment: .center, spacing: SlotColumns.spacing) {
            stateSymbol
            Image(systemName: kind.kind.symbol)
                .foregroundStyle(kind.kind.tint)
                .frame(width: SlotColumns.type)
                .help(kind.name)
            Text(verbatim: reference)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: SlotColumns.reference, alignment: .leading)
                .help(item.workItem.reference)
            titleBlock(showsFacts: false)
            commitment
                .frame(width: SlotColumns.commitment, alignment: .leading)
            progressColumn
                .frame(width: SlotColumns.progress, alignment: .leading)
            Text(verbatim: status ?? "–")
                .font(.callout)
                .foregroundStyle(status == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .frame(width: SlotColumns.status, alignment: .leading)
            assigneeAvatars
                .frame(width: SlotColumns.assignees, alignment: .leading)
            weight
                .frame(width: SlotColumns.weight, alignment: .trailing)
        }
    }

    // MARK: Compact

    private var compact: some View {
        HStack(alignment: .top, spacing: 8) {
            stateSymbol
                .padding(.top, 1)
            titleBlock(showsFacts: true)
            assigneeAvatars
            weight
        }
    }

    // MARK: Parts

    private var stateSymbol: some View {
        Image(systemName: item.isDone ? "checkmark.circle.fill" : item.isInProgress ? "circle.lefthalf.filled" : "circle")
            .foregroundStyle(item.isDone ? Color.green : item.isInProgress ? Color.accentColor : .secondary)
            .frame(width: SlotColumns.state)
            .help(item.isDone ? "Done" : item.isInProgress ? "In progress" : "Open")
    }

    /// The title, a blocked mark before it, and under it the merge requests, the flags and, when narrow, the facts.
    private func titleBlock(showsFacts: Bool) -> some View {
        let width = showsFacts ? nil : SlotColumns.title
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if item.isBlocked {
                    Image(systemName: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .help("Blocked: an item it waits for isn't done yet")
                }
                Text(verbatim: item.workItem.displayTitle)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(item.isDone ? .secondary : .primary)
                    .help(item.workItem.title)
            }
            if showsFacts {
                factsLine
            }
            mergeRequests
            ForEach(item.flags) { flag in
                SlotFlagLine(flag: flag, actions: actions)
            }
            if !item.problems.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.problems) { problem in
                        SlotProblemPill(problem: problem)
                    }
                }
            }
        }
        .frame(minWidth: width, idealWidth: width, maxWidth: .infinity, alignment: .leading)
    }

    /// "#31 · Bug · In Progress", then Planned: the columns' facts folded under the title.
    private var factsLine: some View {
        HStack(spacing: 6) {
            Text(verbatim: ([reference, kind.name] + [status, percent].compactMap { $0 }).joined(separator: " · "))
                .lineLimit(1)
            if !item.isCommitted {
                plannedPill
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var commitment: some View {
        if item.isCommitted {
            Text("Committed")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(commitmentHelp)
        } else {
            plannedPill
        }
    }

    /// "Committed to 2026.48, scheduled for this slot" when it is due later than its slot
    private var commitmentHelp: String {
        guard let due = item.dueSlot else { return "Committed to this slot" }
        return "Committed to \(due.description), scheduled for this slot"
    }

    /// "75 %", or `nil` for an item without a weight, whose progress doesn't count
    private var percent: String? {
        item.weight > 0 ? "\(Int((item.progress * 100).rounded())) %" : nil
    }

    private var progressColumn: some View {
        SlotProgressBar(progress: item.progress, width: SlotColumns.progress - 8)
            .opacity(item.weight > 0 ? 1 : 0.35)
            .help(
                item.weight > 0
                    ? "\(Int((item.progress * 100).rounded())) %: Verified 100 %, in verification 75 %, any other status 0"
                    : "No weight, so it adds nothing to the progress")
    }

    private var plannedPill: some View {
        Text("Planned")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5)))
            .foregroundStyle(.secondary)
            .help("Scheduled for this slot, not committed: no commitment depends on it yet")
    }

    private var assigneeAvatars: some View {
        let people = item.workItem.assignees ?? []
        return HStack(spacing: -5) {
            ForEach(people.prefix(3), id: \.username) { person in
                InitialsAvatar(name: person.name, username: person.username, size: 20)
                    .background(Circle().fill(.background).padding(-1.5))
            }
        }
        .help(people.map(\.displayName).formatted(.list(type: .and)))
    }

    private var weight: some View {
        Text(verbatim: item.workItem.weight.map(String.init) ?? "–")
            .font(.caption.monospacedDigit().weight(.semibold))
            .frame(minWidth: 20)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .help(item.workItem.weight.map { "Weight \($0)" } ?? "No weight")
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

/// A thin progress bar, green once done.
struct SlotProgressBar: View {
    let progress: Double
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.18))
            Capsule()
                .fill(progress >= 1 ? Color.green : .accentColor)
                .frame(width: width * min(max(progress, 0), 1))
        }
        .frame(width: width, height: 5)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

/// A planning problem as a small orange pill: its symbol and words, the details in the tooltip (SLOT-11).
struct SlotProblemPill: View {
    let problem: SlotProblem

    var body: some View {
        Label(problem.kind.text, systemImage: problem.kind.symbol)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(.orange)
            .background(Color.orange.opacity(0.12), in: Capsule())
            .help(problem.detail ?? problem.kind.text)
            .fixedSize()
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
                .lineLimit(1)
            Button(flag.fixTitle) { actions.follow(flag.fixURL) }
                .buttonStyle(.link)
                .lineLimit(1)
                .fixedSize()
        }
        .fixedSize(horizontal: false, vertical: true)
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
