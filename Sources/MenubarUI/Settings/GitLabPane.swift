import AppKit
import MenubarCore
import SwiftUI

/// What the GitLab pane does to the label filters, through the settings store so each change is logged with WI-03's
/// text.
@MainActor
struct GitLabSettingsActions {
    /// puts a label in a list, or in neither
    var setLabel: @MainActor (String, WorkItemFilters.LabelList?) -> Void
    var setLabelsMatch: @MainActor (WorkItemFilters.LabelsMatch) -> Void
    /// "Clear All", without confirmation
    var clearLabels: @MainActor () -> Void

    /// does nothing, for the gallery
    static let none = GitLabSettingsActions(setLabel: { _, _ in }, setLabelsMatch: { _ in }, clearLabels: {})
}

/// Settings → GitLab's form (`docs/design/settings-gitlab.md`): how old GitLab data may be (OD-02), the work item
/// filters (WI-02), and the label filters with their pills and pickers (WI-03, WI-06). It draws only what it is
/// given; the picker's content comes from `picker`.
struct GitLabSettingsForm<Picker: View>: View {
    @Binding var preferences: Preferences
    /// the filter labels GitLab no longer has (WI-06)
    let missingLabels: [String]
    /// GitLab's colors by title
    let colors: [String: String]
    let actions: GitLabSettingsActions
    /// the list whose picker shows, if one does
    @Binding var pickerList: WorkItemFilters.LabelList?
    @ViewBuilder let picker: (WorkItemFilters.LabelList) -> Picker

    private var filters: WorkItemFilters { preferences.workItems }

    var body: some View {
        Form {
            Section {
                SwiftUI.Picker("How old GitLab data may be when it is shown", selection: $preferences.gitLabMaxAgeSeconds) {
                    ForEach(Preferences.gitLabMaxAgeOptions, id: \.self) { seconds in
                        Text(SettingsOptionTitles.seconds(seconds)).tag(seconds)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                SettingsFooter(
                    "Merge requests and work items load when the panel or the window shows them and their data is older "
                        + "than this. Check Now loads them at once.")
            }
            Section {
                menu("Show", selection: $preferences.workItems.scope, title: SettingsOptionTitles.scope)
                menu("Type", selection: $preferences.workItems.type, title: SettingsOptionTitles.type)
                menu("State", selection: $preferences.workItems.state, title: SettingsOptionTitles.state)
                menu("Sort by", selection: $preferences.workItems.sort, title: SettingsOptionTitles.sort)
                SwiftUI.Picker("Show at most", selection: $preferences.workItems.limit) {
                    ForEach(WorkItemFilters.limitOptions, id: \.self) { limit in
                        Text(verbatim: String(limit)).tag(limit)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Work Items")
            } footer: {
                SettingsFooter("Committed work items always show, up to 50; the sort and the limit apply to the others.")
            }
            Section {
                labelList(.with)
                labelList(.without)
                ForEach(missingLabels, id: \.self) { label in
                    StatusLine(.problem, "\(label) is not in GitLab any more (renamed or removed?)") {
                        Button("Remove") { actions.setLabel(label, nil) }
                    }
                }
            } header: {
                HStack {
                    Text("Work Item Labels")
                    Spacer()
                    if !filters.withLabels.isEmpty || !filters.withoutLabels.isEmpty {
                        Button("Clear All", action: actions.clearLabels)
                            .buttonStyle(.link)
                    }
                }
            } footer: {
                SettingsFooter(
                    "Only the work items are filtered. With All of These, a work item needs every label, and only one "
                        + "per scope (the part before ::), so a new label replaces the one of its scope. With Any of "
                        + "These, one is enough. Work items with a label from Must Have None of These never show.")
            }
        }
        .formStyle(.grouped)
    }

    private func menu<Value: Hashable & CaseIterable>(
        _ label: String, selection: Binding<Value>, title: @escaping (Value) -> String
    ) -> some View where Value.AllCases: RandomAccessCollection {
        SwiftUI.Picker(label, selection: selection) {
            ForEach(Value.allCases, id: \.self) { value in
                Text(title(value)).tag(value)
            }
        }
        .pickerStyle(.menu)
    }

    /// One list: its label, the pills, and "Add Label…" with the picker.
    private func labelList(_ list: WorkItemFilters.LabelList) -> some View {
        let labels = list == .with ? filters.withLabels : filters.withoutLabels
        return VStack(alignment: .leading, spacing: 6) {
            if list == .with {
                HStack(spacing: 2) {
                    Text("Must have")
                    Menu {
                        ForEach(WorkItemFilters.LabelsMatch.allCases, id: \.self) { match in
                            Button(SettingsOptionTitles.labelsMatch(match)) { actions.setLabelsMatch(match) }
                        }
                    } label: {
                        Text(SettingsOptionTitles.labelsMatch(filters.labelsMatch))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    Spacer()
                }
            } else {
                Text("Must have none of these")
            }
            HStack(alignment: .top, spacing: 8) {
                SettingsFlowLayout {
                    ForEach(labels, id: \.self) { label in
                        pill(label, in: list)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Add Label…") { pickerList = list }
                    .popover(isPresented: isShowingPicker(list), arrowEdge: .bottom) {
                        picker(list)
                    }
            }
        }
    }

    private func pill(_ label: String, in list: WorkItemFilters.LabelList) -> some View {
        let other: WorkItemFilters.LabelList = list == .with ? .without : .with
        return Button {
            actions.setLabel(label, nil)
        } label: {
            FilterLabelPill(
                title: label, color: colors[label], isGone: missingLabels.contains(label), help: "Remove from the filter")
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove") { actions.setLabel(label, nil) }
            Button("Move to \(SettingsOptionTitles.labelList(other))") { actions.setLabel(label, other) }
        }
    }

    private func isShowingPicker(_ list: WorkItemFilters.LabelList) -> Binding<Bool> {
        Binding(
            get: { pickerList == list },
            set: { shown in
                if !shown, pickerList == list {
                    pickerList = nil
                }
            })
    }
}

/// The label picker's content (`docs/design/settings-gitlab.md`, Label picker): the list's name and rule, the search,
/// the labels grouped by scope as chips, and a footer with a note or the instruction and Done. It draws only what it
/// is given.
struct LabelPickerContent: View {
    let list: WorkItemFilters.LabelList
    let filters: WorkItemFilters
    @Binding var query: String
    /// the last answer; its labels stay while a newer search runs
    let result: LabelSearchResult?
    let isSearching: Bool
    /// the colors known besides the answer's
    let colors: [String: String]
    /// the team's project path, which the search covers with its groups
    let project: String
    let toggle: (String) -> Void
    let done: () -> Void

    /// the picker's size (`settings-gitlab.md`)
    nonisolated static let size = CGSize(width: 400, height: 460)

    static let searchPlaceholder = "Search labels in GitLab"

    /// two lines of `.callout`, the footer's least height, so the divider above it stays put when a note of two lines
    /// replaces the instruction (review SETTINGS-GITLAB-05)
    private static let footerHeight = 2 * NSLayoutManager().defaultLineHeight(for: .preferredFont(forTextStyle: .callout))

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SettingsOptionTitles.labelList(list))
                    .font(.headline)
                Text(subheading)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 8)
            HStack(spacing: 6) {
                // The panel's field, for its Esc: a search clears, then the popover closes (review SETTINGS-GITLAB-04).
                PanelSearchField(text: $query, focusRequest: 0, placeholder: Self.searchPlaceholder, onEscape: done)
                ZStack {
                    if isSearching && !query.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 16, height: 16)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider()
            labels
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                if let problem = result?.problem {
                    StatusLine(.note, problem)
                } else if showsChips {
                    Text("Click a label to add it, again to remove it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(minHeight: Self.footerHeight)
            .padding(14)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var subheading: String {
        switch (list, filters.labelsMatch) {
        case (.with, .all): "A work item needs all of these labels"
        case (.with, .any): "A work item needs any of these labels"
        case (.without, _): "Work items with any of these labels never show"
        }
    }

    private var titles: [String] {
        result?.labels ?? []
    }

    /// whether the list area shows chips, which the instruction is about: not before the first answer, and not with
    /// the system's empty views
    private var showsChips: Bool {
        result != nil && !(titles.isEmpty && (query.isEmpty || !isSearching))
    }

    @ViewBuilder
    private var labels: some View {
        if result == nil {
            // Until the first answer, which comes at once without a search: "No Labels Yet" would flash when labels
            // are known (review SETTINGS-GITLAB-03).
            Color.clear
        } else if !showsChips && query.isEmpty {
            // A word joiner after each slash keeps the path on one line.
            let path = project.replacingOccurrences(of: "/", with: "/\u{2060}")
            ContentUnavailableView(
                "No Labels Yet", systemImage: "tag",
                description: Text(verbatim: "Type a part of a label's name to search \(path) in GitLab."))
        } else if !showsChips {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(MenubarCore.Label.groupedByScope(titles)) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: group.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            SettingsFlowLayout {
                                ForEach(group.labels, id: \.self) { title in
                                    chip(title, inScope: group.scope != nil)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }

    private func chip(_ title: String, inScope: Bool) -> some View {
        let text = inScope ? MenubarCore.Label.scopeAndValue(of: title)?.value ?? title : title
        return LabelChip(
            title: title, text: text, color: result?.colors[title] ?? colors[title],
            state: LabelChipState.of(title, list: list, filters: filters)
        ) {
            toggle(title)
        }
    }

    /// Returns what a click on a chip does to the filters (WI-03): a label in the picker's list leaves it; any other,
    /// also one of the other list, goes into it.
    ///
    /// - Returns: the list to put the label in, or nil to take it out of the filters
    static func target(of label: String, list: WorkItemFilters.LabelList, filters: WorkItemFilters) -> WorkItemFilters.LabelList? {
        if case .inThisList = LabelChipState.of(label, list: list, filters: filters) {
            return nil
        }
        return list
    }
}

/// The label picker from the work items store: it searches as the text changes, 300 ms after typing stops, with the
/// newer search winning (WI-06), and keeps the last answer while one runs.
private struct LabelPicker: View {
    let list: WorkItemFilters.LabelList
    let close: () -> Void
    @Environment(SettingsStore.self) private var settings
    @Environment(WorkItemsStore.self) private var workItems
    @ViewState private var query = ""
    @ViewState private var result: LabelSearchResult?
    @ViewState private var isSearching = false

    var body: some View {
        let filters = settings.preferences.workItems
        LabelPickerContent(
            list: list, filters: filters, query: $query, result: result, isSearching: isSearching,
            colors: workItems.labels.colors, project: settings.primaryTeam.gitLabProject,
            toggle: { label in
                settings.setLabel(label, in: LabelPickerContent.target(of: label, list: list, filters: settings.preferences.workItems))
            },
            done: close)
            .task(id: query) {
                isSearching = true
                do {
                    result = try await workItems.searchLabels(query)
                } catch {
                    // Cancelled: a newer text searches.
                    return
                }
                isSearching = false
            }
    }
}

/// Settings → GitLab, from the settings and work items stores. A change of the filters reloads the work items on
/// screen at once (WI-02).
struct GitLabPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(WorkItemsStore.self) private var workItems
    @ViewState private var pickerList: WorkItemFilters.LabelList?

    var body: some View {
        @Bindable var settings = settings
        GitLabSettingsForm(
            preferences: $settings.preferences,
            missingLabels: workItems.labels.missingFilterLabels(of: settings.preferences.workItems),
            colors: workItems.labels.colors, actions: actions, pickerList: $pickerList
        ) { list in
            LabelPicker(list: list) { pickerList = nil }
        }
    }

    private var actions: GitLabSettingsActions {
        let settings = settings
        return GitLabSettingsActions(
            setLabel: { settings.setLabel($0, in: $1) },
            setLabelsMatch: { settings.setLabelsMatch($0) },
            clearLabels: { settings.clearLabels() })
    }
}
