import MenubarCore
import SwiftUI

/// Settings → Notifications' Inbox section (INBOX-08): for each kind of event whether it lands in the Inbox and counts in
/// the badge and the menu bar's dot, and whether only my projects' items count.
///
/// There are no macOS banners (the user, 2026-11-03): the Inbox, its badge and the dot are the notification.
struct InboxNotificationsSection: View {
    @Binding var rules: InboxNotificationRules

    var body: some View {
        Section {
            routingTable
                .settingsAnchor(.inboxNotifications)
            Toggle(isOn: $rules.onlyMyProjects) {
                SettingsRowLabel(
                    "Only my projects' items count",
                    "Other projects' items stay in the Inbox, but leave the badge and the menu bar dot alone")
            }
            .settingsSwitch()
        } header: {
            SettingsSectionHeader("Inbox")
        } footer: {
            SettingsFooter(
                "GitLab's to-dos are always in the Inbox. Inbox decides what else lands there: changes of your merge requests, Claude's answers, the digest and failed builds. Badge decides what counts.")
        }
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
    private static let columnWidth: CGFloat = 64

    private var routingTable: some View {
        Grid(alignment: .center, horizontalSpacing: 8, verticalSpacing: 9) {
            GridRow {
                Color.clear.frame(height: 1)
                    .gridColumnAlignment(.leading)
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Self.columns, id: \.title) { column in
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
        .padding(.vertical, 2)
    }
}
