import MenubarCore
import SwiftUI

extension InboxRowModel.Tint {
    /// the color of the row's symbol
    var color: Color {
        switch self {
        case .accent: .accentColor
        case .blue: MergeRequestStatus.Color.blue.swiftUI
        case .green: MergeRequestStatus.Color.green.swiftUI
        case .orange: MergeRequestStatus.Color.orange.swiftUI
        case .red: MergeRequestStatus.Color.red.swiftUI
        case .purple: .purple
        case .secondary: .secondary
        case .build(let state): state.color ?? .secondary
        }
    }

    /// the color of the pane's symbols: GitLab's own, following the appearance
    var menuTint: MenuTint {
        switch self {
        case .accent, .blue: .gitLab(.blue)
        case .green: .gitLab(.green)
        case .orange: .gitLab(.orange)
        case .red: .gitLab(.red)
        case .purple: .secondary
        case .secondary: .secondary
        // The pane's build colors are template-tinted for the menu bar; a failed build is red here as in the window.
        case .build(let state): state == .failed ? .gitLab(.red) : state == .unstable ? .gitLab(.orange) : .build(state)
        }
    }
}

/// The coffee break's butler (``AppImages/coffee``) as a row's leading symbol. Where the file is missing the rows keep
/// their cup symbol, so callers check ``AppImages/coffee`` first.
struct CoffeeButlerIcon: View {
    let size: CGFloat

    var body: some View {
        if let butler = AppImages.coffee {
            Image(nsImage: butler)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                // An image's first baseline is its bottom edge, which would lift it above the title. Its middle sits on the
                // title's x-height instead, like a symbol's.
                .alignmentGuide(.firstTextBaseline) { $0.height / 2 + 5 }
                .accessibilityHidden(true)
        }
    }
}

/// An Inbox row in the window's list, in the shape the lists share (``ListRow``; INBOX-02): the kind's symbol in its color
/// (the accent "@" for a mention), line 1 with what happened and to what and the age at the right end, line 2 with the
/// target's chip, the author's avatar and name (and when a snoozed row wakes), and under it GitLab's text, like the comment
/// that mentions me. While the pointer is on the row, its buttons take the age's place: Done, Snooze, Restore.
struct InboxRowContent: View {
    let row: InboxRowModel
    let state: InboxFilter.State
    let actions: InboxActions
    /// asks for the date picker of "Until a Date…"
    let pickDate: @MainActor ([InboxEntry]) -> Void

    @ViewState private var isHovered = false
    /// whether the row was opened: it shows faded
    @Environment(\.inboxIsSeen) private var isSeen
    /// whether GitLab refused the row's change and it was put back: it shakes and tints for a moment
    @Environment(\.inboxIsBounced) private var isBounced
    @ViewState private var shake: CGFloat = 0
    /// `.increased` on the selected row, whose accent fill would swallow the colors
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        ListRow(title: row.title) {
            if row.entry.kind == .coffeeBreak, AppImages.coffee != nil {
                CoffeeButlerIcon(size: 18)
            } else {
                Image(systemName: row.symbol)
                    .foregroundStyle(prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(row.tint.color))
                    .fontWeight(row.isMention ? .semibold : .regular)
                    .help(row.isMention ? "Mentions you" : "")
            }
        } trailing: {
            ZStack(alignment: .trailing) {
                // Both are always there, so the row keeps its width when the buttons come.
                ListRowTime(text: row.age, help: "\(row.age) ago")
                    .opacity(isHovered ? 0 : 1)
                InboxRowButtons(row: row, state: state, actions: actions, pickDate: pickDate)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                    .accessibilityHidden(!isHovered)
            }
        } details: {
            VStack(alignment: .leading, spacing: ListRowMetrics.lineSpacing) {
                InboxDetailsLine(row: row)
                if let excerpt = row.excerpt {
                    Text(verbatim: excerpt)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .foregroundStyle(state == .done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .strikethrough(state == .done && row.entry.isMine)
        // Opened and done rows fade, so what is still new stands out.
        .opacity(isFaded ? 0.6 : 1)
        .background(MergeRequestStatus.Color.red.swiftUI.opacity(isBounced(row.id) ? 0.14 : 0))
        .animation(.easeOut(duration: 0.4), value: isBounced(row.id))
        .offset(x: shake)
        // The row comes back already marked: it shakes as it appears.
        .task(id: isBounced(row.id)) {
            guard isBounced(row.id) else {
                return
            }
            for x: CGFloat in [-7, 7, -5, 5, -2, 0] {
                withAnimation(.linear(duration: 0.05)) { shake = x }
                try? await Task.sleep(for: .milliseconds(55))
            }
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .help(row.help)
    }

    private var isFaded: Bool {
        (state == .done || isSeen(row.id)) && !isHovered
    }
}

/// Whether the Inbox row with an id was just put back after GitLab refused its change.
private struct InboxIsBouncedKey: EnvironmentKey {
    static let defaultValue: @MainActor (String) -> Bool = { _ in false }
}

extension EnvironmentValues {
    /// Returns whether an Inbox row was put back after a refusal. The window's list sets it from the store; the gallery from
    /// its fixtures.
    var inboxIsBounced: @MainActor (String) -> Bool {
        get { self[InboxIsBouncedKey.self] }
        set { self[InboxIsBouncedKey.self] = newValue }
    }
}

/// Whether the Inbox row with an id was opened: each row reads it in its own body.
private struct InboxIsSeenKey: EnvironmentKey {
    static let defaultValue: @MainActor (String) -> Bool = { _ in false }
}

extension EnvironmentValues {
    /// Returns whether an Inbox row was opened. The window's list sets it from the store; the gallery from its fixtures.
    var inboxIsSeen: @MainActor (String) -> Bool {
        get { self[InboxIsSeenKey.self] }
        set { self[InboxIsSeenKey.self] = newValue }
    }
}

/// Line 2 of a row: the target's chip, the author's avatar and name, and for a snoozed row when it wakes. The name gives
/// way first; the chip is cut in the middle, so its number stays.
struct InboxDetailsLine: View {
    let row: InboxRowModel
    /// the avatar's size; the pane's flyout draws it a little smaller
    var avatarSize: CGFloat = 15

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let reference = row.reference {
                ReferenceChip(kind: reference.kind, text: reference.text)
                    .layoutPriority(2)
            }
            if let author = row.author {
                HStack(spacing: 4) {
                    InitialsAvatar(name: author.name, username: author.username, size: avatarSize)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    Text(verbatim: author.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)
            }
            if row.author == nil, let subtitle = row.subtitle {
                Text(verbatim: subtitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
            if let due = row.dueText {
                Label {
                    Text(verbatim: due)
                } icon: {
                    Image(systemName: "calendar")
                }
                .foregroundStyle(row.isOverdue ? AnyShapeStyle(MergeRequestStatus.Color.red.swiftUI) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .fixedSize()
            }
            if let snooze = row.snoozeText {
                Text(verbatim: "· \(snooze)")
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// The buttons that take a row's age while the pointer is on it: Done and Snooze in Pending, Done and Wake Now in
/// Snoozed, Restore in Done.
private struct InboxRowButtons: View {
    let row: InboxRowModel
    let state: InboxFilter.State
    let actions: InboxActions
    let pickDate: @MainActor ([InboxEntry]) -> Void
    @Environment(SettingsStore.self) private var settings: SettingsStore?

    /// Done's tooltip, with the key the user's shortcut map gives it (KEYS-01); none when the shortcut was cleared.
    private var doneHelp: String {
        let shortcut = (settings?.preferences.shortcuts ?? ShortcutMap()).shortcut(for: "inboxDone")
        return shortcut.map { "Done (\($0.display))" } ?? "Done"
    }

    var body: some View {
        HStack(spacing: 4) {
            switch state {
            case .pending:
                if row.entry.canSnooze {
                    InboxSnoozeMenu(entries: [row.entry], actions: actions, pickDate: pickDate) {
                        Image(systemName: "moon.zzz")
                            .accessibilityLabel("Snooze")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Snooze")
                }
                doneButton
            case .snoozed:
                Button {
                    actions.wake([row.entry])
                } label: {
                    Image(systemName: "bell")
                        .accessibilityLabel("Wake Now")
                }
                .buttonStyle(.borderless)
                .help("Wake now")
                doneButton
            case .done:
                Button {
                    actions.restore([row.entry])
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .accessibilityLabel("Restore")
                }
                .buttonStyle(.borderless)
                .help("Restore to the Inbox")
            }
        }
        .foregroundStyle(.secondary)
        .imageScale(.large)
        .fixedSize()
    }

    private var doneButton: some View {
        Button {
            actions.done([row.entry])
        } label: {
            Image(systemName: "checkmark.circle")
                .accessibilityLabel("Done")
        }
        .buttonStyle(.borderless)
        .help(doneHelp)
    }
}

/// The Snooze menu: an hour, tomorrow morning, next week, and a date of the user's choice (INBOX-04). Every entry sleeps:
/// a GitLab to-do in GitLab, the others on this Mac.
struct InboxSnoozeMenu<Label: View>: View {
    let entries: [InboxEntry]
    let actions: InboxActions
    let pickDate: @MainActor ([InboxEntry]) -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Menu {
            ForEach(InboxSnoozeChoice.presets, id: \.self) { choice in
                Button(choice.title) { actions.snooze(entries, choice) }
            }
            Divider()
            Button(InboxSnoozeChoice.until(.distantFuture).title) { pickDate(entries) }
        } label: {
            label
        }
    }
}
