import MenubarCore
import SwiftUI

/// Settings → Menu Bar (APP-11): a live preview of the status item, light and dark, from the same
/// ``StatusLabelModel`` the menu bar draws; what the item shows, each part on or off and dragged into order; and the
/// menu pane's rows, their flyouts and the pane's width. Each group has its "Reset to Default", and the defaults are the
/// look from before the pane existed. It draws only what it is given.
struct MenuBarSettingsForm: View {
    @Binding var preferences: Preferences
    /// the preview's sample, which the gallery sets
    @ViewState var sample = MenuBarPreview.Sample.busy

    /// a drag list row's pitch: its content and the list's own padding
    private static let rowHeight: CGFloat = 40

    private var layout: Binding<MenuBarLayout> {
        $preferences.menuBarLayout
    }

    var body: some View {
        Form {
            SettingsPaneHeader(pane: .menuBar)
            Section {
                MenuBarPreview(layout: preferences.menuBarLayout, style: preferences.iconStyle, sample: sample)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 8, trailing: 12))
                LabeledContent {
                    Picker("Sample", selection: $sample) {
                        ForEach(MenuBarPreview.Sample.allCases, id: \.self) { sample in
                            Text(verbatim: sample.title).tag(sample)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    SettingsRowLabel("Preview with", "Sample counts, not your builds")
                }
            } header: {
                SettingsSectionHeader("Preview")
            }
            itemSection
            partsSection
            paneSection
        }
        .formStyle(.grouped)
        .revealsSettingsFields()
    }

    // MARK: - The item

    private var itemSection: some View {
        Section {
            Toggle(isOn: $preferences.showInMenuBar) {
                SettingsRowLabel("Show in menu bar", "Checks and alerts go on while it's hidden")
            }
            .settingsSwitch()
            .settingsAnchor(.showInMenuBar)
            Picker(selection: layout.butler) {
                ForEach(MenuBarLayout.Butler.allCases, id: \.self) { butler in
                    Text(verbatim: Self.title(of: butler)).tag(butler)
                }
            } label: {
                SettingsRowLabel("Butler", "The icon; it shows whenever nothing else does")
            }
            .pickerStyle(.menu)
            .settingsAnchor(.menuBarIcon)
            LabeledContent {
                Picker("Symbols", selection: $preferences.iconStyle) {
                    ForEach(Preferences.IconStyle.allCases, id: \.self) { style in
                        Text(SettingsOptionTitles.iconStyle(style)).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } label: {
                SettingsRowLabel("Symbols", "Monochrome follows the menu bar, like the system's icons")
            }
            Toggle(isOn: layout.hidesZeroCounts) {
                SettingsRowLabel("Hide zero counts", "Off, every count that is on shows, 0 too")
            }
            .settingsSwitch()
        } header: {
            SettingsSectionHeader("Menu Bar Item")
        }
    }

    private var partsSection: some View {
        let parts = preferences.menuBarLayout.parts
        return Section {
            List {
                ForEach(parts) { part in
                    partRow(part)
                }
                .onMove { source, destination in
                    preferences.menuBarLayout.moveParts(from: source, to: destination)
                }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(height: Self.rowHeight * CGFloat(parts.count) + 8)
            .settingsAnchor(.menuBarParts)
            resetRow(isDefault: preferences.menuBarLayout.isDefaultItem) {
                preferences.menuBarLayout.resetItem()
                preferences.iconStyle = Preferences().iconStyle
            }
        } header: {
            SettingsSectionHeader("Shows")
        } footer: {
            SettingsFooter(
                "Drag the parts into the order you want, left to right. With Merge requests to review on, MegaMonitor "
                    + "also checks GitLab every few minutes while the window and the menu are closed.")
        }
    }

    private func partRow(_ part: MenuBarLayout.Part) -> some View {
        let item = part.part
        return HStack(spacing: 10) {
            Image(systemName: Self.symbol(of: item))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Self.tint(of: item))
                .frame(width: 22)
                .opacity(part.isOn ? 1 : 0.45)
            SettingsRowLabel(Self.title(of: item), Self.caption(of: item))
                .opacity(part.isOn ? 1 : 0.6)
            Spacer(minLength: 8)
            if item == .inbox {
                Picker("Inbox", selection: inboxChoice) {
                    Text("Off").tag(InboxChoice.off)
                    Text("Dot").tag(InboxChoice.dot)
                    Text("Count").tag(InboxChoice.count)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else {
                Toggle(Self.title(of: item), isOn: partBinding(item))
                    .labelsHidden()
                    .settingsSwitch()
            }
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(height: Self.rowHeight - 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("Move Up") { movePart(item, by: -1) }
            Button("Move Down") { movePart(item, by: 1) }
        }
    }

    /// The Inbox's three states in one control: off, or on as a dot or a count.
    private enum InboxChoice: Hashable {
        case off, dot, count
    }

    private var inboxChoice: Binding<InboxChoice> {
        Binding {
            let layout = preferences.menuBarLayout
            guard layout.isOn(.inbox) else { return .off }
            return layout.inboxStyle == .dot ? .dot : .count
        } set: { choice in
            var layout = preferences.menuBarLayout
            layout.setPart(.inbox, isOn: choice != .off)
            if choice != .off {
                layout.inboxStyle = choice == .dot ? .dot : .count
            }
            preferences.menuBarLayout = layout
        }
    }

    private func partBinding(_ part: MenuBarLayout.ItemPart) -> Binding<Bool> {
        Binding {
            preferences.menuBarLayout.isOn(part)
        } set: { isOn in
            preferences.menuBarLayout.setPart(part, isOn: isOn)
        }
    }

    /// Moves a part one place, for the context menu.
    private func movePart(_ part: MenuBarLayout.ItemPart, by step: Int) {
        let parts = preferences.menuBarLayout.parts
        guard let index = parts.firstIndex(where: { $0.part == part }), parts.indices.contains(index + step) else { return }
        preferences.menuBarLayout.moveParts(from: [index], to: step > 0 ? index + 2 : index - 1)
    }

    // MARK: - The pane

    private var paneSection: some View {
        let rows = preferences.menuBarLayout.rows
        return Section {
            List {
                ForEach(rows) { row in
                    paneRow(row)
                }
                .onMove { source, destination in
                    preferences.menuBarLayout.moveRows(from: source, to: destination)
                }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(height: Self.rowHeight * CGFloat(rows.count) + 8)
            .settingsAnchor(.menuPaneRows)
            LabeledContent {
                Picker("Width", selection: layout.paneWidth) {
                    ForEach(MenuBarLayout.PaneWidth.allCases, id: \.self) { width in
                        Text(verbatim: Self.title(of: width)).tag(width)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } label: {
                SettingsRowLabel("Width", "Wider cuts the summaries less")
            }
            .settingsAnchor(.menuPaneWidth)
            resetRow(isDefault: preferences.menuBarLayout.isDefaultPane) {
                preferences.menuBarLayout.resetPane()
            }
        } header: {
            SettingsSectionHeader("Menu")
        } footer: {
            SettingsFooter(
                "What you see when you click the menu bar item. A row's list opens beside the menu on hover; "
                    + "without it, a click opens the row in the main window.")
        }
    }

    private func paneRow(_ row: MenuBarLayout.Row) -> some View {
        HStack(spacing: 10) {
            Image(systemName: MenuAreaIcon.glyph(of: row.section))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .opacity(row.isOn ? 1 : 0.45)
            Text(verbatim: row.section.title)
                .opacity(row.isOn ? 1 : 0.6)
            Spacer(minLength: 8)
            Picker("List", selection: flyoutChoice(row.section)) {
                Text("No List").tag(0)
                Divider()
                ForEach(MenuBarLayout.flyoutRowOptions, id: \.self) { count in
                    Text(verbatim: "\(count) Entries").tag(count)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(!row.isOn)
            .help("How many entries the list beside the menu shows")
            Toggle(row.section.title, isOn: rowBinding(row.section))
                .labelsHidden()
                .settingsSwitch()
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(height: Self.rowHeight - 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("Move Up") { moveRow(row.section, by: -1) }
            Button("Move Down") { moveRow(row.section, by: 1) }
        }
    }

    private func rowBinding(_ section: MainWindowSection) -> Binding<Bool> {
        Binding {
            preferences.menuBarLayout.row(section).isOn
        } set: { isOn in
            preferences.menuBarLayout.updateRow(section) { $0.isOn = isOn }
        }
    }

    /// The flyout as one menu: no list, or how many entries it lists.
    private func flyoutChoice(_ section: MainWindowSection) -> Binding<Int> {
        Binding {
            let row = preferences.menuBarLayout.row(section)
            return row.showsFlyout ? row.flyoutRows : 0
        } set: { count in
            preferences.menuBarLayout.updateRow(section) { row in
                row.showsFlyout = count > 0
                if count > 0 {
                    row.flyoutRows = count
                }
            }
        }
    }

    private func moveRow(_ section: MainWindowSection, by step: Int) {
        let rows = preferences.menuBarLayout.rows
        guard let index = rows.firstIndex(where: { $0.section == section }), rows.indices.contains(index + step) else { return }
        preferences.menuBarLayout.moveRows(from: [index], to: step > 0 ? index + 2 : index - 1)
    }

    private func resetRow(isDefault: Bool, reset: @escaping () -> Void) -> some View {
        HStack {
            Spacer(minLength: 0)
            Button("Reset to Default", action: reset)
                .disabled(isDefault)
        }
    }

    // MARK: - Words and symbols

    static func title(of butler: MenuBarLayout.Butler) -> String {
        switch butler {
        case .whenIdle: "When No Build Is Counted"
        case .always: "Always"
        case .never: "Only When Nothing Else Shows"
        }
    }

    static func title(of width: MenuBarLayout.PaneWidth) -> String {
        switch width {
        case .compact: "Compact"
        case .regular: "Regular"
        case .wide: "Wide"
        }
    }

    static func title(of part: MenuBarLayout.ItemPart) -> String {
        switch part {
        case .problem: "Problem marker"
        case .running: "Running builds"
        case .failed: "Failed builds"
        case .unstable: "Unstable builds"
        case .successful: "Successful builds"
        case .inbox: "Inbox"
        case .reviews: "Merge requests to review"
        case .slot: "Slot countdown"
        }
    }

    static func caption(of part: MenuBarLayout.ItemPart) -> String? {
        switch part {
        case .problem: "Jenkins can't be checked, or you're offline"
        case .inbox: "A red dot, or the number of what waits"
        case .reviews: "Waiting for your review"
        case .slot: "The next date of your committed slot"
        default: nil
        }
    }

    static func symbol(of part: MenuBarLayout.ItemPart) -> String {
        switch part {
        case .problem: Marker.problem
        case .running: BuildState.running.symbol
        case .failed: BuildState.failed.symbol
        case .unstable: BuildState.unstable.symbol
        case .successful: BuildState.successful.symbol
        case .inbox: MainWindowSection.inbox.systemImage
        case .reviews: "eye"
        case .slot: "calendar"
        }
    }

    static func tint(of part: MenuBarLayout.ItemPart) -> Color {
        switch part {
        case .problem, .inbox: .red
        case .failed: BuildState.failed.color ?? .red
        case .unstable: BuildState.unstable.color ?? .orange
        case .successful: BuildState.successful.color ?? .green
        case .reviews: .orange
        case .running, .slot: .secondary
        }
    }
}

/// The status item as the menu bar would draw it, on a slice of a light and a dark menu bar beside the system's own
/// icons, from the same ``StatusLabelModel`` and image the real item uses, with sample counts. The real menu bar can't
/// be drawn in-process; this is its closest stand-in.
struct MenuBarPreview: View {
    let layout: MenuBarLayout
    let style: Preferences.IconStyle
    let sample: Sample

    /// What the preview counts.
    enum Sample: String, CaseIterable, Hashable {
        /// builds running and failed, the Inbox and reviews waiting, the slot close
        case busy
        /// nothing counted and nothing waiting
        case quiet
        /// Jenkins can't be checked, with a few counts left from before
        case problem

        var title: String {
            switch self {
            case .busy: "Busy"
            case .quiet: "Quiet"
            case .problem: "Problem"
            }
        }
    }

    /// Returns the model of a sample, as the real label builds it from the stores.
    static func model(layout: MenuBarLayout, style: Preferences.IconStyle, sample: Sample) -> StatusLabelModel {
        switch sample {
        case .busy:
            StatusLabelModel(
                counts: BuildCounts(running: 1, failed: 2, unstable: 0, successful: 3), style: style, inboxCount: 4,
                reviewCount: 2, slot: StatusLabelModel.SlotCountdown(text: "freeze 3d", isUrgent: true), layout: layout)
        case .quiet:
            StatusLabelModel(style: style, layout: layout)
        case .problem:
            StatusLabelModel(
                problem: .jenkins, counts: BuildCounts(failed: 1), style: style, inboxCount: 1, reviewCount: 0,
                slot: StatusLabelModel.SlotCountdown(text: "freeze 10d", isUrgent: false), layout: layout)
        }
    }

    var body: some View {
        let model = Self.model(layout: layout, style: style, sample: sample)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                bar(model, scheme: .light)
                bar(model, scheme: .dark)
            }
            VStack(spacing: 10) {
                bar(model, scheme: .light)
                bar(model, scheme: .dark)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the menu bar item")
    }

    /// A slice of a menu bar: a wallpaper under a translucent bar, the item highlighted as when its menu is open,
    /// then Wi-Fi, the battery and the clock as the system draws them.
    private func bar(_ model: StatusLabelModel, scheme: ColorScheme) -> some View {
        let dark = scheme == .dark
        let ink: Color = dark ? .white : .black
        return ZStack(alignment: .top) {
            LinearGradient(
                colors: dark
                    ? [Color(red: 0.10, green: 0.12, blue: 0.24), Color(red: 0.28, green: 0.14, blue: 0.34)]
                    : [Color(red: 0.55, green: 0.72, blue: 0.96), Color(red: 0.95, green: 0.76, blue: 0.84)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                StatusLabelContent(model: model)
                    .foregroundStyle(ink)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(ink.opacity(dark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text(verbatim: "Tue 10:42")
                    .monospacedDigit()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ink.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(dark ? Color.black.opacity(0.42) : Color.white.opacity(0.62))
        }
        .frame(height: 64)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .environment(\.colorScheme, scheme)
    }
}

/// Settings → Menu Bar, from the settings store.
struct MenuBarPane: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        MenuBarSettingsForm(preferences: $settings.preferences)
    }
}
