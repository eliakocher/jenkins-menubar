import MenubarCore
import SwiftUI

/// Settings → Notifications' Inbox sections (INBOX-08, INBOX-14, INBOX-15): for each kind of event how it announces itself
/// (Big Panel, Desktop Notification or Inbox Only) and whether it lands in the Inbox and counts in the badge and the menu
/// bar's dot, whether only my projects' items count, the coffee break, and the order of the Inbox's groups.
///
/// Every kind is Inbox Only until the user picks: the Inbox, its badge and the dot are the notification (the user,
/// 2026-11-03). A macOS banner needs the permission, which is asked once when a kind first gets a Desktop Notification.
struct InboxNotificationsSection: View {
    @Binding var rules: InboxNotificationRules
    /// what macOS allows; `nil` while it isn't known yet
    var permission: NotificationPermission?
    var actions: GeneralSettingsActions

    var body: some View {
        Section {
            routingTable
                .settingsAnchor(.inboxNotifications)
            if rules.usesDesktopNotifications, let permission, permission != .allowed {
                StatusLine(
                    permission == .off ? .problem : .note,
                    permission == .off
                        ? "Notifications are off for MegaMonitor: desktop notifications don't show, and those events stay in the Inbox"
                        : "macOS hasn't asked yet: desktop notifications can't show until you allow them"
                ) {
                    Button(permission == .off ? "Open System Settings…" : "Turn On Notifications…") {
                        if permission == .off {
                            actions.openNotificationSettings()
                        } else {
                            actions.turnOnNotifications()
                        }
                    }
                }
            }
            Toggle(isOn: $rules.onlyMyProjects) {
                SettingsRowLabel(
                    "Only my projects' items count",
                    "Other projects' items stay in the Inbox, but leave the badge and the menu bar dot alone")
            }
            .settingsSwitch()
        } header: {
            SettingsSectionHeader("Inbox and Delivery")
        } footer: {
            SettingsFooter(
                "Delivery is how an event announces itself: a Big Panel floats over your windows like a failed build, a Desktop Notification is a macOS banner with Show, Mark Done and Snooze 1 Hour, Inbox Only stays quiet. GitLab's to-dos are always in the Inbox; Inbox decides what else lands there, and Badge what counts.")
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

    private static let columns: [(route: InboxRoutes, title: String)] = [
        (.inbox, "Inbox"), (.badge, "Badge"),
    ]
    private static let columnWidth: CGFloat = 56
    private static let deliveryWidth: CGFloat = 164

    private var routingTable: some View {
        Grid(alignment: .center, horizontalSpacing: 10, verticalSpacing: 9) {
            GridRow {
                Color.clear.frame(height: 1)
                    .gridColumnAlignment(.leading)
                Text(verbatim: "Delivery")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.deliveryWidth, alignment: .leading)
                ForEach(Self.columns, id: \.title) { column in
                    Text(verbatim: column.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.columnWidth)
                }
            }
            ForEach(InboxNotificationRules.settingsKinds, id: \.self) { kind in
                GridRow {
                    Text(verbatim: kind.title)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    deliveryCell(kind)
                    ForEach(Self.columns, id: \.title) { column in
                        if kind == .myTodo, column.route == .inbox {
                            // My own to-dos are always in the Inbox.
                            Toggle(isOn: .constant(true)) { Text(verbatim: "Inbox: \(kind.title)") }
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .disabled(true)
                                .frame(width: Self.columnWidth)
                        } else {
                            Toggle(
                                isOn: Binding(
                                    get: { rules.sends(kind, to: column.route) },
                                    set: { rules.set(column.route, $0, for: kind) })
                            ) {
                                Text(verbatim: "\(column.title): \(kind.title)")
                            }
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .frame(width: Self.columnWidth)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// the kind's delivery picker; none for my own to-dos, which never announce themselves
    @ViewBuilder
    private func deliveryCell(_ kind: InboxEventKind) -> some View {
        if kind == .myTodo {
            Text(verbatim: "Never announced")
                .foregroundStyle(.tertiary)
                .frame(width: Self.deliveryWidth, alignment: .leading)
        } else {
            Picker(
                selection: Binding(
                    get: { rules.delivery(for: kind) },
                    set: { choice in
                        rules.set(choice, for: kind)
                        // macOS asks once; the first Desktop Notification is the moment.
                        if choice == .desktopNotification, permission == .notAsked {
                            actions.turnOnNotifications()
                        }
                    })
            ) {
                ForEach(InboxDelivery.pickerOrder, id: \.self) { delivery in
                    Text(verbatim: delivery.title).tag(delivery)
                }
            } label: {
                Text(verbatim: "Delivery: \(kind.title)")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: Self.deliveryWidth, alignment: .leading)
        }
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
