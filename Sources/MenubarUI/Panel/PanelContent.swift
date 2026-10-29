import AppKit
import MenubarCore
import SwiftUI

/// The panel drawn from plain values (`docs/design/panel.md`): the pinned search field, the builds in a scroll view of
/// measured height with a cap, the pinned summary rows of Merge Requests and Work Items, and the pinned footer.
///
/// A `ScrollView` in the menubar panel has no height of its own, so the content is measured and the scroll view gets
/// `min(measured, cap, limit)`, where the limit keeps the summaries and the footer on screen (`docs/decisions.md`,
/// Task 0.10).
public struct PanelContent: View {
    let data: PanelData
    let actions: PanelActions
    @ViewState private var query: String
    @ViewState private var contentHeight: CGFloat = 0
    @ViewState private var chromeHeight: CGFloat = 0
    @ViewState private var focusRequest = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    /// - Parameters:
    ///   - data: what the stores hold
    ///   - actions: what the rows and the footer do
    ///   - query: the search text to start with; the gallery shows a search with it
    public init(data: PanelData, actions: PanelActions, query: String = "") {
        self.data = data
        self.actions = actions
        _query = ViewState(initialValue: query)
    }

    public var body: some View {
        let model = PanelModel(data, query: query)
        VStack(spacing: 0) {
            PanelSearchField(text: $query, focusRequest: focusRequest, onEscape: actions.close)
                .padding(PanelMetrics.margin)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { searchHeight = $0 }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    sections(model)
                        .padding(.vertical, 6)
                        .id(Self.top)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: max(1, min(contentHeight, PanelMetrics.cap, limit)))
                .onAppear { proxy.scrollTo(Self.top, anchor: .top) }
            }
            if !model.summaries.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(model.summaries, id: \.section) { SummaryRow(item: $0, actions: actions) }
                }
                .padding(.vertical, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { summaryHeight = $0 }
            }
            Divider()
            PanelFooter(footer: model.footer, actions: actions, focusSearch: { focusRequest += 1 })
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .frame(width: PanelMetrics.width)
        .onAppear { focusRequest += 1 }
        .onChange(of: model.summaries.isEmpty) { _, isEmpty in
            if isEmpty { summaryHeight = 0 }
        }
        // A filter left over from the last open would hide builds without saying so.
        .onDisappear { query = "" }
    }

    private static let top = "top"

    @ViewState private var searchHeight: CGFloat = 0
    @ViewState private var footerHeight: CGFloat = 0
    @ViewState private var summaryHeight: CGFloat = 0

    /// The screen's visible height without the search region, the summaries, the footer and a margin, so the footer
    /// stays on screen.
    private var limit: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(PanelMetrics.rowHeight * 3, screen - searchHeight - summaryHeight - footerHeight - PanelMetrics.screenMargin)
    }

    @ViewBuilder private func sections(_ model: PanelModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.problems) { ProblemRow(item: $0, actions: actions) }
            if let builds = model.myBuilds {
                SectionHeader(title: "My Builds")
                if builds.isPlaceholder {
                    PlaceholderRows()
                }
                ForEach(builds.rows) { BuildRow(model: $0, actions: actions) }
                if let note = builds.note {
                    NoteRow(text: note)
                }
            }
            if !model.watching.isEmpty {
                SectionHeader(title: "Watching")
                ForEach(model.watching) { BuildRow(model: $0, actions: actions) }
            }
            if let url = model.allBuilds {
                LinkRow(title: "All Builds in Jenkins", url: url, actions: actions)
            }
            if model.findsNothing {
                ContentUnavailableView.search(text: model.query)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
    }
}

/// The footer: Show N Hidden Builds when builds are hidden; then the three commands people reach for on one line (Check Now, Watch a Build…, Open Window), and under them the time of the last check, Settings… and
/// Quit, quieter. Text only (APP-06). Its shortcuts work while the panel is key.
struct PanelFooter: View {
    let footer: PanelModel.Footer
    let actions: PanelActions
    let focusSearch: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            if let showHidden = footer.showHidden {
                row(showHidden, id: "footer:show-hidden", action: actions.showHidden)
                Divider()
                    .padding(.horizontal, PanelMetrics.margin)
                    .padding(.vertical, 4)
            }
            if typeSize.isAccessibilitySize {
                // Too large for one line: the commands stack as full rows.
                row("Check Now", id: "footer:check-now", action: actions.checkNow)
                    .keyboardShortcut("r")
                row("Watch a Build…", id: "footer:watch", action: actions.watchBuild)
                row("Open Window", id: "footer:open-window", action: actions.openWindow)
                    .keyboardShortcut("0")
                row("Settings…", id: "footer:settings") { actions.openSettings(.general) }
                    .keyboardShortcut(",")
                row("Quit", id: "footer:quit", action: actions.quit)
                    .keyboardShortcut("q")
                checkStatus
                    .panelRowPadding()
            } else {
                commands
                secondary
            }
        }
        .padding(.vertical, 6)
        .background {
            // ⌘F moves the focus to the search field, as in the main window (WIN-05).
            Button("Search", action: focusSearch)
                .keyboardShortcut("f")
                .hidden()
        }
    }

    /// Check Now, Watch a Build… and Open Window, side by side.
    private var commands: some View {
        HStack(spacing: 2) {
            command("Check Now", id: "footer:check-now", help: "Check now (⌘R)", action: actions.checkNow)
                .keyboardShortcut("r")
            command("Watch a Build…", id: "footer:watch", help: "Watch a build by its link or number", action: actions.watchBuild)
            command("Open Window", id: "footer:open-window", help: "Open the main window (⌘0)", action: actions.openWindow)
                .keyboardShortcut("0")
        }
        .padding(.horizontal, 6)
    }

    /// The time of the last check on the left, Settings… and Quit on the right.
    private var secondary: some View {
        HStack(spacing: 2) {
            checkStatus
                .padding(.leading, PanelMetrics.margin - 6 + 8)
            Spacer(minLength: 8)
            quiet("Settings…", id: "footer:settings", help: "Open Settings (⌘,)") { actions.openSettings(.general) }
                .keyboardShortcut(",")
            quiet("Quit", id: "footer:quit", help: "Quit (⌘Q)", action: actions.quit)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    /// "Checking…" with a spinner while a check runs, otherwise "Last checked 10:42".
    @ViewBuilder private var checkStatus: some View {
        if footer.isChecking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if let lastChecked = footer.lastChecked {
            Text(verbatim: lastChecked)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func command(_ title: String, id: String, help: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PanelChipButtonStyle(highlightID: id))
        .help(help)
    }

    private func quiet(_ title: String, id: String, help: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.subheadline)
        }
        .buttonStyle(PanelChipButtonStyle(highlightID: id))
        .help(help)
    }

    private func row(_ title: String, id: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PanelRowButtonStyle(highlightID: id))
    }
}
