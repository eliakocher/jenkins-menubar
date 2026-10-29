import MenubarCore
import SwiftUI

/// The Merge Requests section's detail column (Task 5.3, `docs/design/merge-requests.md`): the selected merge request's
/// status, author and age, pipeline, diff stats, Jenkins build, reviewers, approvals, unresolved threads, GitLab pipeline,
/// description and links; blank without one, or when it left the list.
///
/// It looks the merge request up in the store and its build in Pipelines, both in memory; only the description and the
/// GitLab details load on selection (WIN-02, MR-06 to MR-08). The ages refresh every 10 s.
public struct MergeRequestDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    private let selection: MergeRequest.ID?

    /// - Parameter selection: the selected merge request, by its web URL
    public init(selection: MergeRequest.ID?) {
        self.selection = selection
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            MergeRequestDetailContent(model: detail(at: context.date), actions: .live(model: model, router: router, openURL: openURL))
        }
        .workspaceTagsClickable()
    }
}

extension MergeRequestDetailView {
    /// The selected merge request's detail, with the easter egg line under its diff stats when they call for one.
    private func detail(at date: Date) -> MergeRequestDetailModel? {
        var detail = MergeRequestDetailModel(MergeRequestsData(model, now: date), selection: selection)
        if model.pipelines.preferences.easterEggs, let stats = detail?.mergeRequest.diffStats {
            detail?.eggLine = EggRules.diffLine(stats)
        }
        return detail
    }
}

/// The detail drawn from plain values, for the window and the gallery: a grouped `Form` with the header, the facts in
/// two compact lines and the Jenkins build, the reviewers and the links, as Pipelines' detail.
struct MergeRequestDetailContent: View {
    let model: MergeRequestDetailModel?
    let actions: GitLabSectionActions

    var body: some View {
        if let model {
            Form {
                Section {
                    facts(model)
                } header: {
                    header(model)
                }
                // Each reviewer with their review, and Re-request Review where a review was given (MR-09, MR-10).
                ReviewersSection(model: model, actions: actions)
                    .id(model.mergeRequest.id)
                // The approvals, the open threads and the GitLab pipeline, loaded on selection (MR-06 to MR-08).
                MergeRequestDetailsSections(mergeRequest: model.mergeRequest, actions: actions)
                // Summarize Discussion and Open in Claude Code, while the Claude features are on (AI-03, AI-05).
                ThreadsSummarySection(mergeRequest: model.mergeRequest)
                // After the review state, which the detail is mostly opened for; loaded on selection (WIN-02).
                DescriptionSection(source: DescriptionSource(model.mergeRequest))
                Section("Links") {
                    Link("Changes in GitLab", destination: model.changesURL)
                    Link("Pipelines in GitLab", destination: model.pipelinesURL)
                    // GitLab's new issue page, prefilled with this merge request's link (NEW-04).
                    if let newWorkItem = actions.newWorkItem {
                        Button("New Follow-Up Item") { newWorkItem(.followUp(model.mergeRequest)) }
                            .buttonStyle(.link)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            // Blank without a selection: nothing says "select something" next to a list that may have nothing to select.
            Color.clear
        }
    }

    /// The title wrapping in full, the full reference and "Open Merge Request !14"; the status is the badge below. Return
    /// belongs to the list, so the button isn't the default one.
    private func header(_ model: MergeRequestDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: model.mergeRequest.title)
                .font(.title2)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: model.mergeRequest.reference)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                // The checkout the branch lives in; a click shows it in Workspaces (WS-07).
                WorkspaceTag(subject: .mergeRequest(model.mergeRequest))
            }
            Button(model.openTitle) { actions.open(model.mergeRequest.webURL) }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .font(.body)
        .textCase(nil)
        .padding(.bottom, 8)
    }

    /// The facts as GitLab's header has them, wrapping when narrow: the status badge with the author and the age, then
    /// the pipeline and the diff stats; the Jenkins build keeps its own row.
    @ViewBuilder
    private func facts(_ model: MergeRequestDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PillFlowLayout(spacing: 8, lineSpacing: 6) {
                StatusBadge(text: model.status.text, symbol: model.status.symbol, tint: model.status.color.swiftUI)
                Text(verbatim: "by \(model.author) · updated \(model.updated)")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
            }
            PillFlowLayout(spacing: 8, lineSpacing: 4) {
                // The badge already says "Pipeline failed" when the pipeline decides the status.
                if let pipeline = model.pipeline, !model.status.text.hasPrefix("Pipeline") {
                    SymbolText(symbol: pipeline.symbol, style: pipeline.tint.style, text: "pipeline \(pipeline.word)")
                } else if model.pipeline == nil {
                    Text("No pipeline")
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: model.changes)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let eggLine = model.eggLine {
                Text(verbatim: eggLine)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        if let build = model.jenkinsBuild {
            LabeledContent("Jenkins build") {
                // Side by side while there is room, else the buttons under the build (Pipelines' header buttons).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        buildText(build)
                        jenkinsButtons(model, build: build)
                    }
                    VStack(alignment: .trailing, spacing: 4) {
                        buildText(build)
                        HStack(spacing: 8) { jenkinsButtons(model, build: build) }
                    }
                }
            }
        } else if model.watch != .hidden {
            // Neither mine nor in Pipelines yet: Watch Builds puts it there. Once watched, "Show in Pipelines" shows
            // with the build (WATCH-01).
            LabeledContent("Jenkins build") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.watch.isWatching ? "No build yet" : "Not watched")
                        .foregroundStyle(.secondary)
                    watchBuilds(model)
                }
            }
        }
    }

    private func buildText(_ build: MergeRequestDetailModel.JenkinsBuildFact) -> some View {
        SymbolText(
            symbol: build.state.symbol, style: build.state.color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary),
            text: build.text)
    }

    /// "Show in Pipelines", then Watch Builds when the MR offers it.
    @ViewBuilder
    private func jenkinsButtons(_ model: MergeRequestDetailModel, build: MergeRequestDetailModel.JenkinsBuildFact) -> some View {
        showInPipelines(build)
        watchBuilds(model)
    }

    /// "Watch Builds" watches the MR's job in one click; "Watching" does nothing; nothing for my own MRs (WATCH-01).
    @ViewBuilder
    private func watchBuilds(_ model: MergeRequestDetailModel) -> some View {
        switch model.watch {
        case .hidden:
            EmptyView()
        case .watch:
            Button("Watch Builds") { actions.watchBuilds(model.mergeRequest) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Watch all builds of this merge request")
        case .watching:
            Button("Watching") {}
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
                .help("All builds of this merge request are watched")
        }
    }

    private func showInPipelines(_ build: MergeRequestDetailModel.JenkinsBuildFact) -> some View {
        Button("Show in Pipelines") { actions.showInPipelines(build.job) }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

/// A fact's value: a symbol in its color, then its words in the label color, which wrap and can be selected.
struct SymbolText: View {
    let symbol: String
    let style: AnyShapeStyle
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(style)
            Text(verbatim: text)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

extension MergeRequestDetailModel.Tint {
    /// the symbol's style
    var style: AnyShapeStyle {
        switch self {
        case .label: AnyShapeStyle(.primary)
        case .secondary: AnyShapeStyle(.secondary)
        case .green: AnyShapeStyle(Color.green)
        case .red: AnyShapeStyle(Color.red)
        }
    }
}
