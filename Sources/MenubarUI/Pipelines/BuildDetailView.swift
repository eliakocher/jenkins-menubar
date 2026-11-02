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
/// detail's language (Task 7.0). On top the header: the state badge, the reference and the checkout, the title, the running
/// build's bar, and a strip of chips for the duration, the age and the failed tests. Under it the action row: every
/// frequent action as a bordered button (Rebuild, Notifications, Hide, the console and test results in Jenkins, Copy Link,
/// New Bug), wrapping when narrow. Below, the compact cards (Stages, Failed Tests, Build Info, Recent Builds with the flaky
/// hints, Linked) in one column, or two when wide, then Claude full width. "Open Build in Jenkins" is in the toolbar; only
/// the rare ones (Rebuild with Changes…, the branch) are in the ⋯ menu.
struct BuildDetailContent: View {
    let model: BuildDetailModel?
    let actions: PanelActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.buildInfoFixtures) private var fixtures
    @Environment(AppModel.self) private var appModel: AppModel?

    /// the card the failed tests chip jumps to
    private enum Card: Hashable {
        case tests
    }

    /// what the info and history are loaded for: the build, and whether it runs, since a finished build asks again
    private struct LoadKey: Hashable {
        var build: BuildID
        var isRunning: Bool
    }

    var body: some View {
        if let model {
            DetailPage(id: model.item.id) { proxy in
                header(model) {
                    withAnimation(.snappy) { proxy.scrollTo(Card.tests, anchor: .top) }
                }
                CardColumnsLayout {
                    if showsStagesCard(model) {
                        StagesCard(stages: model.stages, note: model.note)
                    }
                    if let build = model.failedTests {
                        FailedTestsSection(build: build)
                            .id(Card.tests)
                    }
                    if case .build(let row) = model.item {
                        BuildInfoCard(build: row.build, started: model.startedText, branch: branchLink(model), actions: actions)
                        RecentBuildsCard(build: row.build, jobURL: model.jobURL, flakyCheck: model.flakyCheck, actions: actions)
                        if let mergeRequest = model.mergeRequest {
                            LinkedItemsCard(
                                mergeRequest: mergeRequest, workItems: model.workItems, actions: actions.itemLinks)
                        }
                    }
                    // Why Did It Fail?, while the Claude features are on (AI-02, AI-05).
                    if model.canExplain, case .build(let row) = model.item {
                        ExplainBuildSection(build: row.build, page: row.buildPage?.url, inCard: true)
                    }
                }
            }
            // The info and the recent builds, once per build shown (and again when it finishes).
            .task(id: loadKey(model)) {
                if fixtures == nil, case .build(let row) = model.item {
                    await appModel?.buildInfo.load(row.build)
                }
            }
            // GitLab's links from its merge request to the work items, once while they are fresh (MR-12).
            .task(id: model.mergeRequest?.reference) {
                if case .build(let row) = model.item {
                    await appModel?.loadItemLinks(ofBuild: row.build)
                }
            }
        } else {
            // Blank without a selection: nothing says "select something" next to a list that may have nothing to select.
            Color.clear
        }
    }

    private func loadKey(_ model: BuildDetailModel) -> LoadKey? {
        guard case .build(let row) = model.item else { return nil }
        return LoadKey(build: row.build.id, isRunning: row.build.isRunning)
    }

    /// Whether the Stages card shows: not for a waiting job, and not for a build whose stages are never loaded, which
    /// would be a card with a note of no use.
    private func showsStagesCard(_ model: BuildDetailModel) -> Bool {
        model.showsStages && !(model.stages.isEmpty && model.note == BuildDetailModel.StageNote.notLoaded)
    }

    /// The branch of a branch job, which the Build Info card names; a merge request's job has the Linked card.
    private func branchLink(_ model: BuildDetailModel) -> BuildLink? {
        model.links.first { $0.kind == .branch }
    }

    // MARK: The header

    private func header(_ model: BuildDetailModel, jump: @escaping () -> Void) -> some View {
        DetailHeader(title: model.title) {
            StatusBadge(text: model.badge, symbol: model.symbol, tint: tint(of: model))
            if case .build(let row) = model.item {
                Text(verbatim: model.reference)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                // The checkout the build lives in; a click shows it in Workspaces (WS-07).
                WorkspaceTag(subject: .build(row.build))
            }
            if model.notifications.isMuted {
                MutedMark()
            }
        } menu: {
            moreMenu(model)
        } byline: {
            byline(model)
        } chips: {
            chips(model, jump: jump)
        } footer: {
            // Every frequent action as a button, not behind the ⋯ menu.
            BuildActionRow(model: model, actions: actions)
                .padding(.top, 4)
        }
    }

    /// The state's color in the tokens of the merge request detail: a running build blue, the quiet states grey.
    private func tint(of model: BuildDetailModel) -> Color {
        guard case .build(let row) = model.item else { return MergeRequestStatus.Color.neutral.swiftUI }
        return row.state.detailTint
    }

    /// The running build's bar and its times, a waiting job's note, and the rebuild's line.
    @ViewBuilder
    private func byline(_ model: BuildDetailModel) -> some View {
        progress(model)
        if case .waiting = model.item, let note = model.note {
            // A waiting job has no facts: its note stands in their place.
            Text(verbatim: note)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if let rebuild = model.rebuild {
            RebuildLine(rebuild: rebuild, cancel: nil)
                .font(.callout)
        }
    }

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

    /// The duration, the age and the failed tests, wrapping when narrow; the merge request and the branch are in the cards.
    @ViewBuilder
    private func chips(_ model: BuildDetailModel, jump: @escaping () -> Void) -> some View {
        let green = MergeRequestStatus.Color.green.swiftUI
        let red = MergeRequestStatus.Color.red.swiftUI
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
                    DetailChip(symbol: "xmark.octagon.fill", tint: red, text: text, help: "Jump to the Failed Tests card", action: jump)
                } else {
                    DetailChip(symbol: "xmark.octagon.fill", tint: red, text: text, help: "The tests that failed in this build")
                }
            } else if tests.total > 0 {
                DetailChip(symbol: "checkmark.circle", tint: green, text: "\(String(tests.total)) tests passed")
            }
        }
        if model.stages.isEmpty, !model.failedStageNames.isEmpty {
            DetailChip(symbol: "xmark.circle", tint: red, text: "Failed: \(model.failedStageNames.joined(separator: ", "))")
        }
    }

    /// The rare actions: Jenkins's own Build with Parameters page, the branch, and the build's page, which the toolbar
    /// has too. The frequent ones are in the action row.
    @ViewBuilder
    private func moreMenu(_ model: BuildDetailModel) -> some View {
        if let url = model.rebuildWithChanges {
            // Jenkins's own page, where the parameters change before the build (PIPE-09).
            Button("Rebuild with Changes…") { actions.open(url) }
        }
        ForEach(model.links.filter { $0.kind == .branch }) { link in
            Button(link.title) { actions.open(link.url) }
        }
        if let primary = model.primary {
            Button(primary.title) { actions.open(primary.url) }
        }
    }
}
