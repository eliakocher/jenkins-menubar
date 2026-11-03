import AppKit
import MenubarCore
import SwiftUI

// MARK: - What a row says

/// The words and colors of a slot item's row, from its labels (SLOT-09). Pure, so the rows and the tests read the same.
enum SlotItemText {
    /// the kind of work a row shows as a chip
    enum Kind: Hashable {
        case bug
        case feature
        case task
        case epic
        case other

        var tint: Color {
            switch self {
            case .bug: .red
            case .epic: .purple
            // The rest is the neutral grey: the indigo "Feature" chip blurred with the blue work item number beside it
            // (the user, 2026-11-03).
            case .feature, .task, .other: .chipNeutral
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

    /// Returns a type's value without a leading "New ", so the chip stays short: "New Feature" is shown as "Feature".
    static func shortName(_ value: String) -> String {
        let words = value.split(separator: " ")
        guard words.count > 1, words[0].lowercased() == "new" else { return value }
        return words.dropFirst().joined(separator: " ")
    }

    /// Returns the item's kind and its name: from the type label when Team has a prefix and the item has one, else from
    /// the work item's own type.
    static func kind(of item: WorkItem, prefix: String) -> (kind: Kind, name: String) {
        if item.isEpic || item.type == .epic {
            return (.epic, "Epic")
        }
        if let value = value(in: item.labels, prefix: prefix) {
            let lowered = value.lowercased()
            if lowered.contains("bug") { return (.bug, shortName(value)) }
            if lowered.contains("feature") { return (.feature, "Feature") }
            if lowered.contains("task") { return (.task, shortName(value)) }
            return (.other, shortName(value))
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

/// The widths of the columns of the rows. The columns have no titles of their own: each says what it is.
enum SlotColumns {
    /// the width of the icon before an epic's or a commitment's title in its header
    static let headerIcon: CGFloat = 14
    /// what an item row keeps free before its title, so the title lines up with the text of the epic's header above it
    /// (its 8 pt of padding, the icon and the gap are the header's own, and the row has the 8 pt too)
    static let titleInset: CGFloat = headerIcon + 8
    /// the status text with its progress bar under it
    static let status: CGFloat = 116
    /// the avatar and the name
    static let assignees: CGFloat = 148
    static let weight: CGFloat = 34
    static let spacing: CGFloat = 12
    /// the least width the title gets before the columns give way to the compact row
    static let title: CGFloat = 280
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
    let keys: SlotKeys

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            ForEach(group.items) { item in
                SlotItemRow(
                    item: item, project: project, statusPrefix: statusPrefix, typePrefix: typePrefix, layout: layout,
                    isSelected: selection == item.id, select: { select(item.id) }, actions: actions, keys: keys)
            }
        }
    }

    /// The header with its "1 of 3 done", or without it when the list is narrow (the detail beside it
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
                .frame(width: SlotColumns.headerIcon)
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
                .frame(width: SlotColumns.headerIcon)
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
                .help("This slot's share: \(Int((commitment.progress * 100).rounded())) % by weight of its items here")
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

/// How a row shows the keyboard focus.
enum SlotRowFocus {
    static let strokeOpacity = 0.85
    static let lineWidth: CGFloat = 1.5
}

/// One work item of a slot: its title with the blue number, type and merge requests under it, flags, and its facts in
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
    let keys: SlotKeys
    /// shows the keyboard focus whatever the focus is, for the gallery's picture of it
    var showsFocusAlways = false
    @ViewState private var isHovered = false
    @Environment(\.slotOpenInTab) private var openInTab

    var body: some View {
        content
            .opacity(item.isDone ? 0.55 : 1)
            .padding(.leading, SlotColumns.titleInset)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                // The keyboard focus: an accent outline on the selection's tint, as the current slot's card has its
                // outline. The system's square ring is off, as in the header.
                if showsFocus {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor.opacity(SlotRowFocus.strokeOpacity), lineWidth: SlotRowFocus.lineWidth)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { isHovered = $0 }
            .focusable()
            .focusEffectDisabled()
            .focused(keys.focus, equals: .item(item.id))
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .return], action: handle)
            .onTapGesture {
                keys.setKeyboard(false)
                keys.focus.wrappedValue = .item(item.id)
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

    private var showsFocus: Bool {
        showsFocusAlways || (keys.isKeyboard && keys.focus.wrappedValue == .item(item.id))
    }

    /// ↑ and ↓ select the row above or below, across the epics and the cards; Return opens the item as a double click
    /// does (an epic in GitLab's page, which the app can't show); ← closes the card and puts the focus on its header.
    private func handle(_ press: SwiftUI.KeyPress) -> SwiftUI.KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]) else { return .ignored }
        switch press.key {
        case .upArrow, .downArrow:
            keys.setKeyboard(true)
            if let next = keys.neighbor(item.id, press.key == .upArrow ? -1 : 1) {
                keys.go(next)
            }
            return .handled
        case .leftArrow:
            keys.setKeyboard(true)
            keys.fold()
            return .handled
        case .return:
            if let openInTab, !item.workItem.isEpic {
                openInTab(item.id)
            } else {
                actions.follow(item.workItem.webURL)
            }
            return .handled
        default:
            return .ignored
        }
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

    /// The title with its chips under it (the blue number first), the status with its bar, the assignees and the weight. The
    /// columns have no titles; they line up on the first line of the title.
    private var regular: some View {
        HStack(alignment: .firstTextBaseline, spacing: SlotColumns.spacing) {
            titleBlock(showsFacts: false)
            statusColumn
                .frame(width: SlotColumns.status, alignment: .leading)
            assigneeColumn(avatarSize: 20, font: .callout)
                .frame(width: SlotColumns.assignees, alignment: .leading)
            weight
                .frame(width: SlotColumns.weight, alignment: .trailing)
        }
    }

    // MARK: Compact

    private var compact: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            titleBlock(showsFacts: true)
            weight
        }
    }

    // MARK: Parts

    /// The title, a blocked mark before it, and under it the chips (the type, planned, the merge requests), the flags
    /// and, when narrow, the facts.
    private func titleBlock(showsFacts: Bool) -> some View {
        let width = showsFacts ? nil : SlotColumns.title
        return VStack(alignment: .leading, spacing: 4) {
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
            chipsLine
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

    /// "In Progress · 75 %  Alex Kim +1": the columns' facts folded under the title when the card is narrow.
    private var factsLine: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(verbatim: [status, percent].compactMap { $0 }.joined(separator: " · "))
                .lineLimit(1)
                .layoutPriority(1)
            assigneeColumn(avatarSize: 16, font: .caption)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// The line under the title: the blue number first, then the type as a chip, "Planned" when the item isn't committed, and
    /// its merge requests (the user, 2026-11-03: the number's column is gone, its chip leads this line).
    private var chipsLine: some View {
        HStack(spacing: 6) {
            WorkItemNumberChip(text: reference, help: item.workItem.reference)
                .fixedSize()
            Text(verbatim: kind.name)
                .inlineChip(tint: kind.kind.tint)
                .fixedSize()
                .help("Type: \(kind.name)")
            if !item.isCommitted {
                plannedChip
            }
            mergeRequests
        }
    }

    /// "75 %", or `nil` for an item without a weight, whose progress doesn't count
    private var percent: String? {
        item.weight > 0 ? "\(Int((item.progress * 100).rounded())) %" : nil
    }

    /// The status text with the progress bar under it.
    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: status ?? "–")
                .font(.callout)
                .foregroundStyle(status == nil ? .tertiary : .secondary)
                .lineLimit(1)
            SlotProgressBar(progress: item.progress, width: SlotColumns.status - 12)
                .opacity(item.weight > 0 ? 1 : 0.35)
                .help(
                    item.weight > 0
                        ? "\(Int((item.progress * 100).rounded())) %: Verified 100 %, in verification 75 %, any other status 0"
                        : "No weight, so it adds nothing to the progress")
        }
    }

    /// Shown under the title of an item that isn't committed, so nothing gets lost with the column gone. An outline, so
    /// it reads apart from the filled chips.
    private var plannedChip: some View {
        Text("Planned")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.45)))
            .fixedSize()
            .help("Scheduled for this slot, not committed: no commitment depends on it yet")
    }

    /// The first assignee's avatar and name, "Alex Kim +1" for more, every name in the tooltip.
    @ViewBuilder
    private func assigneeColumn(avatarSize: CGFloat, font: Font) -> some View {
        let people = item.workItem.assignees ?? []
        if let first = people.first {
            HStack(spacing: 6) {
                InitialsAvatar(name: first.name, username: first.username, size: avatarSize)
                (Text(verbatim: first.displayName)
                    + Text(verbatim: people.count > 1 ? " +\(people.count - 1)" : "").foregroundStyle(.tertiary))
                    .font(font)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(people.map(\.displayName).formatted(.list(type: .and)))
        } else {
            Text(verbatim: "–")
                .font(font)
                .foregroundStyle(.tertiary)
        }
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

    /// The chips of the open merge requests (a draft is open); when none is open and one is merged, the quiet word "Merged"
    /// instead (the user, 2026-11-03: "show the MR chip only if the MR is open, otherwise show 'merged'"); closed ones are
    /// left out. "No merge request" once GitLab answered that there is none alive, as the flag counts them.
    @ViewBuilder
    private var mergeRequests: some View {
        let open = item.mergeRequests.filter { $0.mergeRequest.state == .opened }
        let merged = item.mergeRequests.filter { $0.mergeRequest.state == .merged }
        if !open.isEmpty {
            ForEach(open) { mergeRequest in
                SlotMergeRequestChip(mergeRequest: mergeRequest, project: project, actions: actions)
            }
        } else if !merged.isEmpty {
            SlotMergedNote(mergeRequests: merged, project: project)
        } else if item.mergeRequestsLoaded, !item.workItem.isEpic, item.isCommitted {
            Text(verbatim: "No merge request")
                .font(.caption)
                .foregroundStyle(.secondary)
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

/// A merge request as the green "!12" with its build's result after it; the merge request's state is in the tooltip.
struct SlotMergeRequestChip: View {
    let mergeRequest: SlotMergeRequest
    let project: String
    let actions: GitLabSectionActions

    var body: some View {
        Button {
            actions.follow(mergeRequest.mergeRequest.webURL)
        } label: {
            // The MR chip of the lists, green whatever the state, with its build's result after the number.
            MergeRequestNumberChip(
                text: GitLabText.shortReference(mergeRequest.mergeRequest.reference, project: project),
                build: mergeRequest.build.map { BuildState($0.signal) })
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var help: String {
        let reference = GitLabText.shortReference(mergeRequest.mergeRequest.reference, project: project)
        let build = mergeRequest.build.map { build in
            let name = switch build.signal {
            case .green: "green"
            case .red: "red"
            case .running: "running"
            }
            return ", build \(build.label.map { $0 + " " } ?? "")\(name)"
        }
        let word = WorkItemMergeRequestChip.isDraft(mergeRequest.mergeRequest.title) ? "draft" : "open"
        let item = ReferenceKind.tooltip(reference, state: word, title: mergeRequest.mergeRequest.title)
        return item + (build ?? ", no build known")
    }
}

/// "Merged" in place of the chips of an item whose merge requests are all merged: quiet text with a small purple check; the
/// tooltip lists them, "!12404 · Title".
struct SlotMergedNote: View {
    let mergeRequests: [SlotMergeRequest]
    let project: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.purple)
            Text(verbatim: "Merged")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help(Self.help(mergeRequests, project: project))
    }

    /// One line per merge request: "!12404 · Title".
    static func help(_ mergeRequests: [SlotMergeRequest], project: String) -> String {
        mergeRequests.map {
            ReferenceKind.tooltip(
                GitLabText.shortReference($0.mergeRequest.reference, project: project), title: $0.mergeRequest.title)
        }.joined(separator: "\n")
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
