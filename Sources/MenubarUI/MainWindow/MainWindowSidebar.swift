import MenubarCore
import SwiftUI

/// The main window's sidebar: the four sections in one group, in the order of ⌘1 to ⌘4, each with its count and, while
/// it has a problem of its own, the red marker (`docs/design/main-window.md`, "Sidebar"; WIN-01).
struct MainWindowSidebar: View {
    @Binding var section: MainWindowSection
    /// each section's count; a section without one shows no badge
    var badges: [MainWindowSection: Int] = [:]
    /// the marker's tooltip of each section with a problem of its own
    var markers: [MainWindowSection: String] = [:]

    var body: some View {
        List(selection: selection) {
            ForEach(MainWindowSection.allCases, id: \.self) { section in
                Label {
                    HStack(spacing: 4) {
                        Text(section.title)
                        if let help = markers[section] {
                            Image(systemName: Marker.problem)
                                .foregroundStyle(.red)
                                .help(help)
                        }
                    }
                } icon: {
                    Image(systemName: section.systemImage)
                }
                .badge(badges[section].map { Text(verbatim: String($0)) })
                .tag(section)
            }
        }
        .listStyle(.sidebar)
    }

    /// The list wants an optional selection; the sidebar always has a section, so clearing it keeps the old one.
    private var selection: Binding<MainWindowSection?> {
        Binding(
            get: { section },
            set: { newValue in
                if let newValue {
                    section = newValue
                }
            })
    }
}
