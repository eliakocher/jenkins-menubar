import MenubarCore
import SwiftUI

/// Settings → Appearance's "Sidebar": the sections in the order the sidebar and ⌘1 and on have them, to drag into the
/// order the user wants, with "Reset to Default" (WIN-01). The same preference a drag in the sidebar changes. Digest
/// stays in the list while Claude is off: it keeps its place and the sidebar skips it.
struct SidebarOrderSection: View {
    @AppStorage(SectionOrder.key) private var stored = ""

    /// a row's pitch in the list: its content and the list's own padding
    private static let rowHeight: CGFloat = 36

    var body: some View {
        let order = SectionOrder.merged(stored: stored)
        Section {
            List {
                ForEach(Array(order.enumerated()), id: \.element) { index, section in
                    row(section, index: index, order: order)
                }
                .onMove { source, destination in
                    stored = SectionOrder.stored(SectionOrder.moving(order, shown: order, from: source, to: destination))
                }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(height: Self.rowHeight * CGFloat(order.count) + 8)
            .settingsAnchor(.sidebarOrder)
            HStack {
                Spacer(minLength: 0)
                Button("Reset to Default") { stored = "" }
                    .disabled(stored.isEmpty)
            }
        } header: {
            SettingsSectionHeader("Sidebar")
        } footer: {
            SettingsFooter(
                "Drag the sections into the order you want. ⌘1 and on follow it, and you can also drag the rows in the sidebar itself.")
        }
    }

    private func row(_ section: MainWindowSection, index: Int, order: [MainWindowSection]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: section.systemImage)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(verbatim: section.title)
            Spacer(minLength: 8)
            Text(verbatim: index < 9 ? "⌘\(index + 1)" : "")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(height: Self.rowHeight - 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Move Up") { move(section, in: order, by: -1) }
        .accessibilityAction(named: "Move Down") { move(section, in: order, by: 1) }
        .contextMenu {
            Button("Move Up") { move(section, in: order, by: -1) }
                .disabled(index == 0)
            Button("Move Down") { move(section, in: order, by: 1) }
                .disabled(index == order.count - 1)
        }
    }

    /// Moves a section one place up or down, for the menu and VoiceOver.
    private func move(_ section: MainWindowSection, in order: [MainWindowSection], by step: Int) {
        guard let index = order.firstIndex(of: section), order.indices.contains(index + step) else { return }
        let destination = step > 0 ? index + 2 : index - 1
        stored = SectionOrder.stored(SectionOrder.moving(order, shown: order, from: [index], to: destination))
    }
}
