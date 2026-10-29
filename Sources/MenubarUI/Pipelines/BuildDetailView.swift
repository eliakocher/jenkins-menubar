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
            BuildDetailContent(
                model: selection.flatMap { BuildDetailModel(job: $0, data: PipelinesData(model, now: context.date)) },
                actions: actions)
        }
        .workspaceTagsClickable()
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

/// The build detail drawn from plain values, for the window and the gallery.
struct BuildDetailContent: View {
    let model: BuildDetailModel?
    let actions: PanelActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let model {
            Form {
                Section {
                    facts(model)
                } header: {
                    header(model)
                }
                if model.showsStages {
                    Section("Stages") {
                        stages(model)
                    }
                }
                if let build = model.failedTests {
                    FailedTestsSection(build: build)
                }
                // Why Did It Fail? and Open in Claude Code, while the Claude features are on (AI-02, AI-05).
                if model.canReportBug, case .build(let row) = model.item {
                    ExplainBuildSection(build: row.build, page: row.buildPage?.url)
                }
                if !model.links.isEmpty || model.rebuildWithChanges != nil {
                    Section("Links") {
                        ForEach(model.links) { link in
                            Link(link.title, destination: link.url)
                        }
                        // Jenkins's own page, where the parameters change before the build (PIPE-09).
                        if let url = model.rebuildWithChanges {
                            Link("Rebuild with Changes…", destination: url)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            // Blank without a selection: nothing says "select something" next to a list that may have nothing to select.
            Color.clear
        }
    }

    /// The state's symbol, the title and the reference, then the buttons; they stack when the column is narrow.
    private func header(_ model: BuildDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: model.symbol)
                    .font(.title2)
                    .foregroundStyle(model.color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.title)
                        .font(.title2)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: model.reference)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        // The checkout the build lives in; a click shows it in Workspaces (WS-07).
                        if case .build(let row) = model.item {
                            WorkspaceTag(subject: .build(row.build))
                        }
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    buttons(model)
                }
                VStack(alignment: .leading, spacing: 8) {
                    buttons(model)
                }
            }
            .font(.body)
            if let build = model.flakyCheck {
                FlakyHintLine(build: build)
            }
            if let rebuild = model.rebuild {
                RebuildLine(rebuild: rebuild, cancel: nil)
                    .font(.body)
            }
        }
        .textCase(nil)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func buttons(_ model: BuildDetailModel) -> some View {
        if let primary = model.primary {
            Button(primary.title) { actions.open(primary.url) }
                .buttonStyle(.borderedProminent)
        }
        if model.canRebuild, case .build(let row) = model.item {
            // While queued, the button cancels, so the line under the buttons reads "Rebuilding…" alone (PIPE-09).
            if model.rebuild?.canCancel == true {
                Button("Cancel Rebuild") { actions.cancelRebuild(row.build.jobKey) }
                    .buttonStyle(.bordered)
            } else {
                Button("Rebuild") { actions.rebuildBuild(row.build.id) }
                    .buttonStyle(.bordered)
                    .disabled(model.rebuild?.isUnderWay == true)
            }
        }
        if model.canReportBug, let newWorkItem = actions.newWorkItem, case .build(let row) = model.item {
            Button("New Bug from This Build") { newWorkItem(.bugFromBuild(row.build, row.buildPage?.url)) }
                .buttonStyle(.bordered)
        }
        if model.canHide, case .build(let row) = model.item {
            Button("Hide Until the Next Build") { actions.hide(row.build) }
                .buttonStyle(.bordered)
        }
        if model.canStopWatching {
            Button("Stop Watching") { actions.stopWatching(model.item.id) }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func facts(_ model: BuildDetailModel) -> some View {
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
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        ForEach(model.facts) { fact in
            LabeledContent(fact.label) {
                HStack(spacing: 4) {
                    if let state = fact.state {
                        Image(systemName: state.symbol)
                            .foregroundStyle(state.color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                    }
                    Text(verbatim: fact.value)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        }
        if case .waiting = model.item, let note = model.note {
            // A waiting job has no facts: its note stands in their place.
            Text(verbatim: note)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func stages(_ model: BuildDetailModel) -> some View {
        if let note = model.note {
            Text(verbatim: note)
                .foregroundStyle(.secondary)
        }
        ForEach(model.stages) { stage in
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(verbatim: stage.name)
                } icon: {
                    Image(systemName: stage.symbol)
                        .foregroundStyle(stage.color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                }
                Spacer(minLength: 8)
                Text(verbatim: stage.word)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(verbatim: stage.duration ?? "")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
                    .fixedSize()
            }
        }
    }
}
