import MenubarCore
import SwiftUI

/// Settings → Notifications' table and the Inbox's own sections (INBOX-08, INBOX-14, INBOX-15): one row per event with a
/// single choice, Pop-up, Banner, Inbox or Off (``DeliverySegments``), and whether it counts in the Red Dot (the Inbox's
/// badge and the menu bar's dot); whether only my projects' items count, the coffee break, and the order of the Inbox's
/// groups.
///
/// The four build rows are the only place that says what a finished build does: a build that fails, succeeds, mine or
/// watched. Every choice but Off also puts an entry in the Inbox. A macOS banner needs the permission, which is asked
/// once when a row first gets a Banner.
struct InboxNotificationsSection: View {
    @Binding var rules: InboxNotificationRules
    /// what macOS allows; `nil` while it isn't known yet
    var permission: NotificationPermission?
    var actions: GeneralSettingsActions

    /// whether the pane is wide enough for the words beside the symbols
    @ViewState private var isWide = true

    /// the pane width from which the choices show their words
    private static let wideFrom: CGFloat = 560
    /// the width of the event names column; longer names wrap
    private static let eventWidth: CGFloat = 170

    init(rules: Binding<InboxNotificationRules>, permission: NotificationPermission?, actions: GeneralSettingsActions) {
        _rules = rules
        self.permission = permission
        self.actions = actions
    }

    var body: some View {
        Section {
            routingTable
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsAnchor(.inboxNotifications)
                .onGeometryChange(for: Bool.self) { $0.size.width >= Self.wideFrom } action: { isWide = $0 }
            Toggle(isOn: $rules.onlyMyProjects) {
                SettingsRowLabel(
                    "Only my projects' items count",
                    "Other projects' items stay in the Inbox, but leave the Red Dot alone")
            }
            .settingsSwitch()
        } header: {
            SettingsSectionHeader("What Each Event Does")
        } footer: {
            SettingsFooter(
                "Pop-up, Banner and Inbox each add an entry to the Inbox, which waits there until you mark it done; Off does nothing at all. Pop-ups and banners of builds play the result's sound. Aborted builds and other results alert nothing. Red Dot decides what counts on the Inbox and the menu bar's dot. GitLab's own to-dos are always in the Inbox: Off only stops their pop-up, except GitLab's pipeline failed, which Off hides here (it is never marked done in GitLab); it is Off by default, since the failed Jenkins build says the same.")
        }
        InboxGroupOrderSection(rules: $rules)
        Section {
            Toggle(isOn: $rules.coffeeBreak) {
                SettingsRowLabel("Coffee break", "A short line in your Inbox on weekdays")
            }
            .settingsSwitch()
            .settingsAnchor(.coffeeBreak)
            if rules.coffeeBreak {
                LabeledContent {
                    DatePicker("Time", selection: coffeeTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                } label: {
                    SettingsRowLabel("Time")
                }
            }
        } header: {
            SettingsSectionHeader("Coffee Break")
        } footer: {
            SettingsFooter(
                "Claude's Haiku writes the line when the Claude features are on; otherwise one of the built-in lines comes. A Mac that wakes more than half an hour late skips that day.")
        }
    }

    /// the time picker's date: today's date carries the hour and the minute
    private var coffeeTime: Binding<Date> {
        Binding(
            get: {
                let minutes = rules.coffeeMinutes
                return Calendar.current.date(bySettingHour: minutes / 60 % 24, minute: minutes % 60, second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                rules.coffeeMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }

    // MARK: - The table

    private static let redDotWidth: CGFloat = 56

    private var routingTable: some View {
        Grid(alignment: .center, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text(verbatim: "Event")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.leading)
                    .frame(width: Self.eventWidth, alignment: .leading)
                Text(verbatim: "What it does")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.leading)
                Text(verbatim: "Red Dot")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.redDotWidth)
                    .help("Counts on the Inbox and the menu bar's dot")
            }
            ForEach(InboxNotificationRules.settingsKinds, id: \.self) { kind in
                if kind == InboxNotificationRules.settingsKinds.first(where: { !$0.isFinishedBuild }) {
                    Divider()
                        .gridCellUnsizedAxes(.horizontal)
                        .gridCellColumns(3)
                }
                GridRow {
                    Text(verbatim: kind.title)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: Self.eventWidth, alignment: .leading)
                    deliveryCell(kind)
                    Toggle(
                        isOn: Binding(
                            get: { rules.sends(kind, to: .badge) },
                            set: { rules.set(.badge, $0, for: kind) })
                    ) {
                        Text(verbatim: "Red Dot: \(kind.title)")
                    }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: Self.redDotWidth)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// the kind's single choice; for my own to-dos only Inbox, since they never announce themselves
    private func deliveryCell(_ kind: InboxEventKind) -> some View {
        DeliverySegments(
            selection: Binding(
                get: { rules.delivery(for: kind) },
                set: { choice in
                    rules.set(choice, for: kind)
                    // macOS asks once; the first Banner is the moment.
                    if choice == .banner, permission == .notAsked {
                        actions.turnOnNotifications()
                    }
                }),
            available: kind.availableDeliveries, isBuild: kind.isFinishedBuild, symbolsOnly: !isWide, subject: kind.title)
    }
}

/// The order of the Inbox's groups, to drag into the order the user wants, with "Reset to Default" (INBOX-15). The Inbox
/// list and the pane's flyout follow it. The same shape as Settings → Appearance's sidebar order.
struct InboxGroupOrderSection: View {
    @Binding var rules: InboxNotificationRules

    /// a row's pitch in the list: its content and the list's own padding
    private static let rowHeight: CGFloat = 36

    var body: some View {
        let order = rules.groupOrder
        Section {
            List {
                ForEach(Array(order.enumerated()), id: \.element) { index, group in
                    row(group, index: index, order: order)
                }
                .onMove { source, destination in
                    rules.setGroupOrder(InboxGroupOrder.moving(order, from: source, to: destination))
                }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(height: Self.rowHeight * CGFloat(order.count) + 8)
            .settingsAnchor(.inboxGroupOrder)
            HStack {
                Spacer(minLength: 0)
                Button("Reset to Default") { rules.setGroupOrder(InboxGroup.allCases) }
                    .disabled(rules.groupOrderNames.isEmpty)
            }
        } header: {
            SettingsSectionHeader("Inbox Order")
        } footer: {
            SettingsFooter(
                "Drag the groups into the order you want. The Inbox and the menu bar pane's list follow it, so what matters most to you is on top.")
        }
    }

    private func row(_ group: InboxGroup, index: Int, order: [InboxGroup]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: group.systemImage)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(verbatim: group.title)
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(height: Self.rowHeight - 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Move Up") { move(group, in: order, by: -1) }
        .accessibilityAction(named: "Move Down") { move(group, in: order, by: 1) }
        .contextMenu {
            Button("Move Up") { move(group, in: order, by: -1) }
                .disabled(index == 0)
            Button("Move Down") { move(group, in: order, by: 1) }
                .disabled(index == order.count - 1)
        }
    }

    /// Moves a group one place up or down, for the menu and VoiceOver.
    private func move(_ group: InboxGroup, in order: [InboxGroup], by step: Int) {
        guard let index = order.firstIndex(of: group), order.indices.contains(index + step) else { return }
        let destination = step > 0 ? index + 2 : index - 1
        rules.setGroupOrder(InboxGroupOrder.moving(order, from: [index], to: destination))
    }
}
