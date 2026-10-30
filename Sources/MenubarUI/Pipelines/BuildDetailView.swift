import MenubarCore
import SwiftUI

/// The Pipelines section's detail column (Task 5.2, `docs/design/pipelines.md`): the selected job's build, its stages,
/// failed tests, links and actions; blank without one, or when the job left the list.
///
/// It reads the stores from the environment and draws a ``BuildDetailContent``, refreshed every 10 s for a running
/// build's times. The job stays selected when its next build starts, so the detail moves on to it.
public struct BuildDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    private let selection: String?

    /// - Parameter selection: the selected job, `Build.job` (a WAITING job: `WatchedJob.job`)
    public init(selection: String?) {
        self.selection = selection
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            BuildDetailContent(model: detail(at: context.date), actions: actions)
        }
        .workspaceTagsClickable()
    }

    /// The selected job's detail with its merge request and their work items (MR-12).
    private func detail(at date: Date) -> BuildDetailModel? {
        var detail = selection.flatMap { BuildDetailModel(job: $0, data: PipelinesData(model, now: date)) }
        if case .build(let row)? = detail?.item {
            detail?.mergeRequest = model.mergeRequest(ofBuild: row.build)
            detail?.workItems = model.workItems(ofBuild: row.build)
        }
        return detail
    }

    /// The window's actions; Hide and Stop Watching take the build out of the list, so the focus goes back there, with
    /// nothing selected (`pipelines.md`, Keyboard).
    private var actions: PanelActions {
        var actions = PanelActions.mainWindow(model, router: router, openURL: openURL)
        let router = router
        let hide = actions.hide
        let stopWatching = actions.stopWatching
        actions.hide = { build in
            hide(build)
            router.selection.pipelines = nil
            router.focusList()
        }
        actions.stopWatching = { job in
            stopWatching(job)
            router.selection.pipelines = nil
            router.focusList()
        }
        return actions
    }
}

/// The build detail drawn from plain values, for the window and the gallery: a scrolling page in the merge request
/// detail's language. On top the header: the state badge, the reference and the checkout, the title, the running
/// build's bar, and a strip of chips for the duration, the age, the failed tests, the flaky hints and the merge request.
/// Below, the compact cards (Stages, Failed Tests) in one column, or two when wide, then Claude full width. "Open Build in Jenkins" is in the toolbar;
/// the other actions and the links are in the ⋯ menu, and Rebuild is next to the chips.
struct BuildDetailContent: View {
    let model: BuildDetailModel?
    let actions: PanelActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var appModel: AppModel?

    /// the card the failed tests chip jumps to
    private enum Card: Hashable {
        case tests
    }

    var body: some View {
        if let model {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header(model) {
                            withAnimation(.snappy) { proxy.scrollTo(Card.tests, anchor: .top) }
                        }
                        if showsStagesCard(model) || model.failedTests != nil || model.canReportBug {
                            CardColumnsLayout {
                                if showsStagesCard(model) {
                                    StagesCard(stages: model.stages, note: model.note)
                                }
                                if let build = model.failedTests {
                                    FailedTestsSection(build: build)
                                        .id(Card.tests)
                                }
                                // Why Did It Fail? and Open in Claude Code, while the Claude features are on (AI-02, AI-05).
                                if model.canReportBug, case .build(let row) = model.item {
                                    ExplainBuildSection(build: row.build, page: row.buildPage?.url, inCard: true)
                                }
                            }
                        }
                    }
                    .sectionNavigation(proxy: proxy)
                    .pageContentWidth()
                }
                // Another build starts at the top, with its own disclosures.
                .id(model.item.id)
                // GitLab's links from its merge request to the work items, once while they are fresh (MR-12).
                .task(id: model.mergeRequest?.reference) {
                    if case .build(let row) = model.item {
                        await appModel?.loadItemLinks(ofBuild: row.build)
                    }
                }
            }
            .toolbar {
                if let primary = model.primary {
                    ToolbarItem(placement: .primaryAction) {
                        Button { actions.open(primary.url) } label: {
                            Label(primary.title, systemImage: "arrow.up.forward.app")
                        }
                        .help(primary.title)
                    }
                }
            }
        } else {
            // Blank without a selection: nothing says "select something" next to a list that may have nothing to select.
            Color.clear
        }
    }

    /// Whether the Stages card shows: not for a waiting job, and not for a build whose stages are never loaded, which
    /// would be a card with a note of no use.
    private func showsStagesCard(_ model: BuildDetailModel) -> Bool {
        model.showsStages && !(model.stages.isEmpty && model.note == BuildDetailModel.StageNote.notLoaded)
    }

    // MARK: The header

    private func header(_ model: BuildDetailModel, jump: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                StatusBadge(text: model.badge, symbol: model.symbol, tint: tint(of: model))
                if case .build(let row) = model.item {
                    Text(verbatim: model.reference)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    // The checkout the build lives in; a click shows it in Workspaces (WS-07).
                    WorkspaceTag(subject: .build(row.build))
                }
                Spacer(minLength: 8)
                moreMenu(model)
            }
            Text(verbatim: model.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            progress(model)
            if case .waiting = model.item, let note = model.note {
                // A waiting job has no facts: its note stands in their place.
                Text(verbatim: note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            chips(model, jump: jump)
                .padding(.top, 4)
            if let build = model.flakyCheck {
                FlakyHintLine(build: build, asChips: true)
            }
            rebuildRow(model)
        }
    }

    /// The state's color in the tokens of the merge request detail: a running build blue, the quiet states grey.
    private func tint(of model: BuildDetailModel) -> Color {
        guard case .build(let row) = model.item else { return MergeRequestStatus.Color.neutral.swiftUI }
        switch row.state {
        case .running: return MergeRequestStatus.Color.blue.swiftUI
        case .failed: return MergeRequestStatus.Color.red.swiftUI
        case .unstable: return MergeRequestStatus.Color.orange.swiftUI
        case .successful: return MergeRequestStatus.Color.green.swiftUI
        case .aborted, .other: return MergeRequestStatus.Color.neutral.swiftUI
        }
    }

    /// The running build's bar and its times.
    @ViewBuilder
    private func progress(_ model: BuildDetailModel) -> some View {
        if let progress = model.progress {
            VStack(alignment: .leading, spacing: 4) {
                switch progress {
                case .fraction(let fraction):
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                case .indeterminate:
                    // With Reduce Motion, the hourglass and the elapsed time carry the state (the panel's rule).
                    if !reduceMotion {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
                if let timing = model.timing {
                    Text(verbatim: timing)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    /// The duration, the age, the failed tests and the merge request, wrapping when narrow.
    private func chips(_ model: BuildDetailModel, jump: @escaping () -> Void) -> some View {
        let green = MergeRequestStatus.Color.green.swiftUI
        let red = MergeRequestStatus.Color.red.swiftUI
        return PillFlowLayout(spacing: 6, lineSpacing: 6) {
            if let started = model.startedText {
                if let finished = model.finishedText {
                    if let duration = model.durationText {
                        DetailChip(symbol: "timer", text: duration, help: "How long the build ran")
                    }
                    DetailChip(symbol: "clock", text: "Finished \(finished)", help: "Started \(started)")
                } else {
                    DetailChip(symbol: "play.circle", text: "Started \(started)", help: "When the build started")
                }
            }
            if let tests = model.tests {
                if tests.failed > 0 {
                    let text = "\(String(tests.failed)) of \(String(tests.total)) failed"
                    if model.failedTests != nil {
                        DetailChip(symbol: "xmark.octagon.fill", tint: red, text: text, help: "Show the failed tests", action: jump)
                    } else {
                        DetailChip(symbol: "xmark.octagon.fill", tint: red, text: text, help: "Failed tests")
                    }
                } else if tests.total > 0 {
                    DetailChip(symbol: "checkmark.circle", tint: green, text: "\(String(tests.total)) tests passed")
                }
            }
            if model.stages.isEmpty, !model.failedStageNames.isEmpty {
                DetailChip(symbol: "xmark.circle", tint: red, text: "Failed: \(model.failedStageNames.joined(separator: ", "))")
            }
            // The merge request of the build and its work items show in the app (MR-12); a branch has no page there and
            // opens in GitLab.
            if let mergeRequest = model.mergeRequest {
                MergeRequestLinkChip(mergeRequest: mergeRequest, actions: actions.itemLinks)
                WorkItemLinkChips(
                    items: model.workItems, project: mergeRequest.project, named: false, actions: actions.itemLinks)
            }
            ForEach(model.links.filter { $0.kind == .branch || ($0.kind == .mergeRequest && model.mergeRequest == nil) }) { link in
                DetailChip(
                    symbol: link.kind == .mergeRequest ? "arrow.triangle.merge" : "arrow.triangle.branch",
                    text: link.title.replacingOccurrences(of: "Open ", with: "").replacingOccurrences(of: "Show ", with: ""),
                    help: link.title
                ) {
                    if link.kind == .mergeRequest { actions.follow(link.url) } else { actions.open(link.url) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Rebuild, or Cancel Rebuild while the new build is queued, with the rebuild's line next to it (PIPE-09).
    @ViewBuilder
    private func rebuildRow(_ model: BuildDetailModel) -> some View {
        let canRebuild = model.canRebuild
        if canRebuild || model.rebuild != nil {
            HStack(alignment: .center, spacing: 10) {
                if canRebuild, case .build(let row) = model.item {
                    // While queued, the button cancels, so the line next to it reads "Rebuilding…" alone.
                    if model.rebuild?.canCancel == true {
                        Button { actions.cancelRebuild(row.build.jobKey) } label: {
                            Label("Cancel Rebuild", systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button { actions.rebuildBuild(row.build.id) } label: {
                            Label("Rebuild", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.rebuild?.isUnderWay == true)
                    }
                }
                if let rebuild = model.rebuild {
                    RebuildLine(rebuild: rebuild, cancel: nil)
                        .font(.callout)
                }
            }
            .padding(.top, 2)
        }
    }

    /// The other actions and the links the header doesn't show as chips.
    @ViewBuilder
    private func moreMenu(_ model: BuildDetailModel) -> some View {
        // Notifications for This Job is always there, so the menu is too (ALERT-08).
        do {
            Menu {
                if let primary = model.primary {
                    Button(primary.title) { actions.open(primary.url) }
                }
                ForEach(model.links) { link in
                    Button(link.title) { if link.kind == .mergeRequest { actions.follow(link.url) } else { actions.open(link.url) } }
                }
                // Jenkins's own page, where the parameters change before the build (PIPE-09).
                if let url = model.rebuildWithChanges {
                    Button("Rebuild with Changes…") { actions.open(url) }
                }
                if let primary = model.primary, case .build = model.item {
                    Divider()
                    Button("Copy Link") { actions.copy(primary.url) }
                }
                Divider()
                JobNotificationsMenu(notifications: model.notifications) {
                    actions.setJobNotifications(model.item.id, $0)
                }
                if model.canReportBug, let newWorkItem = actions.newWorkItem, case .build(let row) = model.item {
                    Button("New Bug from This Build") { newWorkItem(.bugFromBuild(row.build, row.buildPage?.url)) }
                }
                if model.canHide, case .build(let row) = model.item {
                    Button("Hide Until the Next Build") { actions.hide(row.build) }
                }
                if model.canStopWatching {
                    Button("Stop Watching") { actions.stopWatching(model.item.id) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }
}
