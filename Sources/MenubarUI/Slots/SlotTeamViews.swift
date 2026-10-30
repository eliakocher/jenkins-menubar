import MenubarCore
import SwiftUI

/// The chips above the slots (SLOT-07): one selected, the slot group's issues loading beside them.
struct SlotChipBar: View {
    let chips: [SlotChip]
    @Binding var chip: SlotChip
    var isLoading = false

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(chips) { candidate in
                        Button {
                            chip = candidate
                        } label: {
                            Text(verbatim: candidate.title)
                                .font(.callout.weight(candidate == chip ? .semibold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .foregroundStyle(candidate == chip ? Color.white : .primary)
                                .background(
                                    Capsule().fill(candidate == chip ? Color.accentColor : Color.secondary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(candidate == chip ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.never)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .help("Loading the slot group's issues")
            }
        }
    }
}

/// A slot's people, committed points and load against the chip's capacity (SLOT-08).
struct SlotLoadLine: View {
    let slot: SlotSummary

    var body: some View {
        if !slot.items.isEmpty || !slot.planned.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    if !slot.members.isEmpty {
                        PeopleLine(people: slot.members, size: 20, maxAvatars: 8)
                            .font(.callout)
                    }
                    Spacer(minLength: 8)
                    Text(verbatim: pointsText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(pointsHelp)
                }
                if let load = slot.load {
                    loadBar(load)
                }
            }
        }
    }

    private var pointsText: String {
        var text = "\(slot.committedPoints) points committed"
        if let capacity = slot.capacity, let load = slot.load {
            text += " · \(Int((load * 100).rounded())) % of \(capacity)"
        }
        return text
    }

    private var pointsHelp: String {
        var parts = ["The weight of the \(slot.items.count) committed items, done ones too."]
        if slot.unweightedCount > 0 {
            parts.append("\(slot.unweightedCount) have no weight and don't count.")
        }
        if !slot.planned.isEmpty {
            parts.append("\(slot.planned.count) planned items aren't counted.")
        }
        return parts.joined(separator: " ")
    }

    private func loadBar(_ load: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(load > 1 ? Color.orange : Color.accentColor)
                    .frame(width: geometry.size.width * min(load, 1))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Load")
        .accessibilityValue("\(Int((load * 100).rounded())) percent")
    }
}

/// An epic with its items in the slot, or the items without one (SLOT-08).
struct SlotEpicSection: View {
    let group: SlotEpicGroup
    let project: String
    var statusPrefix = ""
    let actions: GitLabSectionActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(group.items) { item in
                SlotItemRow(item: item, project: project, statusPrefix: statusPrefix, actions: actions)
                    .padding(.leading, 12)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: group.epic == nil ? "tray" : "flag.fill")
                .foregroundStyle(group.epic == nil ? Color.secondary : .purple)
                .frame(width: 18)
            if let epic = group.epic {
                Button {
                    actions.open(epic.webURL)
                } label: {
                    Text(verbatim: epic.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help(epic.reference)
                .contextMenu {
                    Button("Open in GitLab") { actions.open(epic.webURL) }
                    Button("Copy Link") { actions.copy(epic.webURL) }
                }
            } else {
                Text("No epic")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(verbatim: "\(group.items.count { $0.isDone }) of \(group.items.count) done")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: group.progress)
                .progressViewStyle(.linear)
                .frame(width: 60)
                .help("\(Int((group.progress * 100).rounded())) % by weight; an item without a weight counts 1")
        }
    }
}

/// An item's facts at the row's end: Planned, blocked, status, weight and the assignees.
struct SlotItemFacts: View {
    let item: SlotItem
    var statusPrefix = ""

    var body: some View {
        HStack(spacing: 8) {
            if !item.isCommitted {
                Text("Planned")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5)))
                    .foregroundStyle(.secondary)
                    .help("Scheduled for this slot, not committed")
            }
            if item.workItem.isBlocked == true {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.red)
                    .help("Blocked by an open item")
            }
            if let status {
                Text(verbatim: status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(verbatim: item.workItem.weight.map(String.init) ?? "–")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(minWidth: 18)
                .padding(.horizontal, 3)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .help(item.workItem.weight.map { "Weight \($0)" } ?? "No weight")
            HStack(spacing: -4) {
                ForEach((item.workItem.assignees ?? []).prefix(3), id: \.username) { person in
                    InitialsAvatar(name: person.name, username: person.username, size: 18)
                        .background(Circle().fill(.background).padding(-1))
                }
            }
            .help((item.workItem.assignees ?? []).map(\.displayName).formatted(.list(type: .and)))
        }
    }

    /// the status label's value, like "InProgress", spaced as "In Progress"
    private var status: String? {
        guard !statusPrefix.isEmpty,
            let label = item.workItem.labels.first(where: { $0.title.hasPrefix(statusPrefix) })
        else { return nil }
        let value = String(label.title.dropFirst(statusPrefix.count))
        var spaced = ""
        for character in value {
            if character.isUppercase, let last = spaced.last, last.isLowercase {
                spaced.append(" ")
            }
            spaced.append(character)
        }
        return spaced.isEmpty ? nil : spaced
    }
}
