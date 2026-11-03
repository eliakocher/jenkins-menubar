import AppKit
import MenubarCore
import SwiftUI

/// The chips above the slots (SLOT-07), combinable as in the team's tool: a click turns a chip on or off; chips of one
/// kind (status, type, members) are alternatives, different kinds narrow each other down. Everyone, the reset, shows as
/// on while nothing else is. The slot group's issues load beside them.
struct SlotChipBar: View {
    let chips: [SlotChip]
    @Binding var selection: SlotChipSelection
    var isLoading = false

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(chips.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0, Self.group(candidate) != Self.group(chips[index - 1]) {
                            Rectangle()
                                .fill(Color.primary.opacity(0.15))
                                .frame(width: 1, height: 14)
                                .padding(.horizontal, 2)
                                .accessibilityHidden(true)
                        }
                        chip(candidate)
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

    /// Everyone, the filters (status and type), and the members, each a block of its own
    private static func group(_ chip: SlotChip) -> Int {
        switch chip.field {
        case nil: 0
        case .status, .type: 1
        case .members: 2
        }
    }

    private func chip(_ candidate: SlotChip) -> some View {
        let isOn = selection.isActive(candidate)
        return Button {
            selection = selection.toggled(candidate)
        } label: {
            Text(verbatim: candidate.title)
                .font(.callout.weight(isOn ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(isOn ? Color.white : .primary)
                .background(Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(candidate == .all ? "Show everything: turns the other chips off" : "Turn on or off; chips of one kind show either, kinds narrow down")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The quiet line under the chips while the team chips come from squad labels (SLOT-07): the planning tool filters by
/// the team's members, so with Team's teams the chips match it; the gear opens that field, "Suggest Members" lists who
/// carries each squad label, to paste there. Read only.
struct SlotSquadHint: View {
    let suggestion: String
    @ViewState private var isShowingSuggestion = false

    var body: some View {
        HStack(spacing: 6) {
            Text("From squad labels. The web tool filters by team members: set them in Settings → Team.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            SettingsGearButton(field: .squads)
                .controlSize(.small)
            if !suggestion.isEmpty {
                Button("Suggest Members") { isShowingSuggestion = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .popover(isPresented: $isShowingSuggestion, arrowEdge: .bottom) {
                        SlotMemberSuggestion(suggestion: suggestion)
                    }
            }
        }
    }
}

/// The popover of "Suggest Members": the team value in Team's format, with Copy. Shown in the gallery too.
struct SlotMemberSuggestion: View {
    let suggestion: String
    @ViewState private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested Members")
                .font(.headline)
            Text("The assignees of the loaded items under each squad label, each person in the squad with most of their items. Paste it into Settings → Team → Teams and their members, and check it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: suggestion)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(suggestion, forType: .string)
                    copied = true
                }
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}
