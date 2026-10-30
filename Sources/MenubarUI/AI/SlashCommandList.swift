import MenubarCore
import SwiftUI

/// The "/" list above a chat's field (AI-09): the user's commands and skills that match what was typed after the
/// slash, a name in monospace, where it comes from, its one-line description, and a quiet "May need interaction" on the
/// ones that ask questions along the way. The highlighted row is the one Return inserts.
struct SlashCommandList: View {
    /// the commands that match, best first
    let commands: [SlashCommand]
    let highlighted: Int
    let pick: (SlashCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if commands.isEmpty {
                        Text("No command or skill matches")
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                    ForEach(Array(commands.enumerated()), id: \.offset) { index, command in
                        Button {
                            pick(command)
                        } label: {
                            row(command)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            index == highlighted ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .id(index)
                    }
                }
                .padding(4)
            }
            .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
        }
        .frame(maxHeight: 230)
        .fixedSize(horizontal: false, vertical: commands.count < 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.15)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands and skills")
    }

    private func row(_ command: SlashCommand) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "/" + command.name)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .lineLimit(1)
            if !command.summary.isEmpty {
                Text(verbatim: command.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if command.mayNeedInteraction {
                Label("May need interaction", systemImage: "questionmark.bubble")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    .help("It may ask questions along the way. A chat can't answer them: try it, and use Continue in Claude Code if it stops.")
            }
            Text(verbatim: command.source.label)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one-line hint the "/" list shows while Use My Claude Code Setup is off, with a button to the setting.
struct SlashCommandHint: View {
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "slash.circle")
                .foregroundStyle(.secondary)
            Text("Commands and skills need Use My Claude Code Setup, in Settings.")
                .foregroundStyle(.secondary)
            Button("Open Settings…", action: openSettings)
                .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
