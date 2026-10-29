import MenubarCore
import SwiftUI

/// The Activity section drawn from plain values, for the window and the gallery: the old Logs' look with the new
/// features (LOG-04; the user, 2026-10-29, "old look, new brains"). Full width, top to bottom: the check times chart,
/// the filter bar, the log by day with its bottom bar; the details of the selected entry in an inspector on the right,
/// on demand.
///
/// - The list stays in the view tree while an empty state lies over it, so its scroll position and the focus survive
///   a search without results (ACTIVITY-04).
/// - The list takes the keyboard focus when the section shows and on a focus request (⌘4, after Clear), never on its
///   own while people type in the search field.
/// - A selected entry scrolls into view once the rows exist, after the first read (ACTIVITY-03).
struct ActivityContent<Inspector: View>: View {
    let data: ActivityContentData
    @Binding var selection: Set<ActivityItem.ID>
    @Binding var level: ActivityLevelFilter
    @Binding var source: ActivityEntry.Source?
    @Binding var chartExpanded: Bool
    @Binding var hoveredTime: Date?
    @Binding var isInspectorShown: Bool
    /// whether "Clear all activity?" shows, for the toolbar's Clear Activity… and File › Clear Activity…
    @Binding var isConfirmingClear: Bool
    let actions: ActivityActions
    /// grows when the list should take the keyboard focus
    var focusRequest = 0
    private let inspector: Inspector
    @FocusState private var isFocused: Bool
    /// whether the list is too narrow for the row's columns side by side
    @ViewState private var isCompact = false

    init(
        data: ActivityContentData, selection: Binding<Set<ActivityItem.ID>>, level: Binding<ActivityLevelFilter>,
        source: Binding<ActivityEntry.Source?>, chartExpanded: Binding<Bool>, hoveredTime: Binding<Date?>,
        isInspectorShown: Binding<Bool>, isConfirmingClear: Binding<Bool>, actions: ActivityActions, focusRequest: Int = 0,
        @ViewBuilder inspector: () -> Inspector
    ) {
        self.data = data
        _selection = selection
        _level = level
        _source = source
        _chartExpanded = chartExpanded
        _hoveredTime = hoveredTime
        _isInspectorShown = isInspectorShown
        _isConfirmingClear = isConfirmingClear
        self.actions = actions
        self.focusRequest = focusRequest
        self.inspector = inspector()
    }

    var body: some View {
        VStack(spacing: 0) {
            CheckTimesChartView(
                chart: data.chart, isLoaded: data.isLoaded, isExpanded: $chartExpanded, hoveredTime: $hoveredTime)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            Divider()
            ActivityFilterBar(
                level: $level, source: $source, countText: data.isLoaded && data.totalCount > 0 ? data.countText : nil)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            Divider()
            list
                .frame(minHeight: 0, maxHeight: .infinity)
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width < ActivityRow.compactListWidth
        } action: { compact in
            // On the next turn: changed within the layout pass, the rows would update from within the table's own
            // delegate calls, which AppKit reports as a reentrant operation.
            Task { isCompact = compact }
        }
        .inspector(isPresented: $isInspectorShown) {
            inspector
                .frame(minHeight: 0, maxHeight: .infinity)
                // 320 so the sidebar, the list and the inspector fit the window's least width, 820 pt.
                .inspectorColumnWidth(min: 280, ideal: 320, max: 640)
        }
        // The subtitle is the shell's (`MainWindowShellModel`), from `ActivityContentData.subtitle`.
        .clearActivityConfirmation(isPresented: $isConfirmingClear) {
            actions.clear()
            isFocused = true
        }
        .task {
            // Once when the section shows, outside the update that builds the list.
            isFocused = true
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(rows) { day in
                    Section(day.title) {
                        ForEach(day.items) { item in
                            ActivityRow(item: item, isCompact: isCompact) { inspect([item.id]) }
                                .redacted(reason: data.isLoaded ? [] : .placeholder)
                                .listRowBackground(ActivityRowTint.color(of: item.entry.level))
                        }
                    }
                }
            }
            .listStyle(.inset)
            .allowsHitTesting(data.isLoaded)
            .focused($isFocused)
            .contextMenu(forSelectionType: ActivityItem.ID.self) { ids in
                Button("Show Details") { inspect(ids) }
                    .disabled(ids.isEmpty)
                Button("Copy") {
                    if let text = actions.copyText(ids) {
                        ActivityPasteboard.put(text)
                    }
                }
                .disabled(ids.isEmpty)
            } primaryAction: { ids in
                // Double-click or Return: the details, as in the old Logs.
                inspect(ids)
            }
            // Edit › Copy (⌘C): the selected entries only, disabled without a selection (LOG-04).
            .onCopyCommand(perform: copyAction)
            .safeAreaBar(edge: .bottom) {
                bottomBar
            }
            .overlay {
                emptyState
            }
            .task(id: data.isLoaded) {
                guard data.isLoaded else { return }
                // A restored selection scrolls into view once the list has its rows: they come in this update, so the
                // scroll waits for the next turn of the main actor (ACTIVITY-03).
                await Task.yield()
                scrollToSelection(proxy)
            }
            .onChange(of: focusRequest) {
                isFocused = true
                scrollToSelection(proxy)
            }
        }
    }

    /// Shows the inspector with these entries selected.
    private func inspect(_ ids: Set<ActivityItem.ID>) {
        guard !ids.isEmpty else { return }
        selection = ids
        isInspectorShown = true
    }

    /// Edit › Copy's action: nil without a selection, which disables the command
    private var copyAction: (() -> [NSItemProvider])? {
        guard !selection.isEmpty else { return nil }
        let selection = selection
        return {
            guard let text = actions.copyText(selection) else { return [] }
            return [NSItemProvider(object: text as NSString)]
        }
    }

    /// the days to show: two placeholder rows under "Today" before the first read
    private var rows: [ActivityDay] {
        data.isLoaded ? data.days : [ActivityDay(day: .distantPast, title: "Today", items: Self.placeholders)]
    }

    /// The empty state over the list, which has no rows then.
    @ViewBuilder
    private var emptyState: some View {
        switch data.emptyState {
        case .noActivity:
            ContentUnavailableView {
                Label("No Activity Yet", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Requests, builds, alerts and setting changes show up here.")
            } actions: {
                Button("Check Now") { actions.checkNow() }
            }
        case .nothingToShow:
            ContentUnavailableView {
                Label("Nothing to Show", systemImage: "line.3.horizontal.decrease")
            } description: {
                Text("No entries match the filters.")
            } actions: {
                Button("Show All Entries") { actions.showAllEntries() }
            }
        case .noSearchResults(let text):
            ContentUnavailableView.search(text: text)
        case nil:
            EmptyView()
        }
    }

    /// The bottom bar: the 1000-row cap, then where the log starts and how big it is; nothing while the log is empty.
    @ViewBuilder
    private var bottomBar: some View {
        if data.truncationMessage != nil || data.footerText != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let truncation = data.truncationMessage {
                    Text(verbatim: truncation)
                }
                if let footer = data.footerText {
                    Text(verbatim: footer)
                        .lineLimit(2)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard data.isLoaded, selection.count == 1, let id = selection.first else { return }
        // Without an anchor: the least scroll that shows it, none when it is in view already.
        proxy.scrollTo(id)
    }

    /// two rows of the usual length, drawn as placeholders before the first read
    private static var placeholders: [ActivityItem] {
        [
            ActivityItem(
                id: "placeholder-0",
                entry: ActivityEntry(
                    time: .distantPast, level: .debug, source: .jenkins,
                    message: "Checked Jenkins: 3 requests, 0.54s together", outcome: .ok("OK")),
                position: 1),
            ActivityItem(
                id: "placeholder-1",
                entry: ActivityEntry(
                    time: .distantPast, level: .debug, source: .gitlab, message: "POST MergeRequests in 0.41s",
                    outcome: .ok("200")),
                position: 0),
        ]
    }
}

/// The filters, as in the old Logs (LOG-04): a segmented control for the level and a pop-up for the source, then how
/// many entries pass them and the search. The store remembers both choices. In a narrow window the count goes first
/// (the subtitle has it too), then the pop-up moves under the segmented control.
struct ActivityFilterBar: View {
    @Binding var level: ActivityLevelFilter
    @Binding var source: ActivityEntry.Source?
    /// "N entries"; nil before the first read and while the log is empty
    let countText: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                levelPicker
                sourcePicker
                Spacer(minLength: 12)
                if let countText {
                    Text(verbatim: countText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            HStack(spacing: 12) {
                levelPicker
                sourcePicker
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                levelPicker
                sourcePicker
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var levelPicker: some View {
        Picker("Level", selection: $level) {
            ForEach(ActivityLevelFilter.allCases, id: \.self) { filter in
                Text(verbatim: filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Everything: also each request and check. Events: all but those. Problems: warnings and errors.")
    }

    private var sourcePicker: some View {
        Picker("Source", selection: $source) {
            Text("All Sources").tag(ActivityEntry.Source?.none)
            Divider()
            ForEach(ActivityEntry.Source.allCases, id: \.self) { source in
                Text(verbatim: source.displayName).tag(ActivityEntry.Source?.some(source))
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("Show the entries of one source")
    }
}

extension View {
    /// "Clear all activity?" on the window (`docs/design/activity.md`, "Clear confirmation"): Clear is the default
    /// button, without the destructive style, since the person chose Clear [alerts › Buttons].
    ///
    /// - Parameters:
    ///   - isPresented: whether it shows
    ///   - clear: what Clear does
    func clearActivityConfirmation(isPresented: Binding<Bool>, clear: @escaping @MainActor () -> Void) -> some View {
        alert("Clear all activity?", isPresented: isPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Clear") { clear() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("This deletes the log, the check times and the kept requests. You can't undo this.")
        }
    }
}
