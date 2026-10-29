import MenubarCore
import SwiftUI

/// The Work Items section's detail column (Task 5.4, `docs/design/work-items.md`): the selected work item's header with
/// its state, type, age and slot, description, label pills, related merge requests and links; blank without one, or when it left the list.
///
/// It looks the item, its related MRs and the Merge Requests store's MRs up in memory; selecting asks only for the
/// description, once per update of the item (WIN-02). The age refreshes every 10 s.
public struct WorkItemDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    private let selection: WorkItem.ID?

    /// - Parameter selection: the selected work item, by its full reference
    public init(selection: WorkItem.ID?) {
        self.selection = selection
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            WorkItemDetailContent(model: detail(at: context.date), actions: .live(model: model, router: router, openURL: openURL))
        }
    }
}

extension WorkItemDetailView {
    /// The selected work item's detail, with the easter egg line under its last update on the item's birthday.
    private func detail(at date: Date) -> WorkItemDetailModel? {
        let data = WorkItemsData(model, now: date)
        var detail = WorkItemDetailModel(data, selection: selection)
        if model.pipelines.preferences.easterEggs, let item = detail?.workItem {
            detail?.eggLine = EggRules.birthday(reference: data.shortReference(of: item), updatedAt: item.updatedAt, now: date)
        }
        return detail
    }
}

/// The detail drawn from plain values, for the window and the gallery: a grouped `Form` with the header and its facts
/// line, the description, the labels and the related merge requests. The item's own link is the header's button; there is
/// no Links section.
struct WorkItemDetailContent: View {
    let model: WorkItemDetailModel?
    let actions: GitLabSectionActions

    var body: some View {
        if let model {
            Form {
                Section {
                    facts(model)
                        .padding(.vertical, 2)
                } header: {
                    header(model)
                }
                // The item's own text right under its facts: what the user selected it for (WIN-02).
                DescriptionSection(source: DescriptionSource(model.workItem))
                // Open in Claude Code, while the Claude features are on (AI-05).
                ClaudeWorkItemSection(workItem: model.workItem)
                Section("Labels") {
                    if model.labels.isEmpty {
                        Text(verbatim: WorkItemDetailModel.noLabels)
                            .foregroundStyle(.secondary)
                    } else {
                        PillFlowLayout {
                            ForEach(model.labels) { LabelPill(label: $0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Section {
                    related(model.related)
                } header: {
                    Text("Related Merge Requests")
                } footer: {
                    if !model.relatedFooters.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.relatedFooters, id: \.self) { footer in
                                Text(verbatim: footer)
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            // Blank without a selection: nothing says "select something" next to a list that may have nothing to select.
            Color.clear
        }
    }

    /// The marker, the title wrapping in full, the full reference and "Open Work Item #31". Return belongs to the list,
    /// so the button isn't the default one.
    private func header(_ model: WorkItemDetailModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let marker = model.marker {
                Image(systemName: WorkItemRowStyle.symbol(of: marker))
                    .font(.title2)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: model.workItem.displayTitle)
                    .font(.title2)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(verbatim: model.workItem.reference)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button(model.openTitle) { actions.open(model.workItem.webURL) }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .font(.body)
        .textCase(nil)
        .padding(.bottom, 8)
    }

    /// One line, as GitLab's issue header has it, wrapping when narrow: the state badge, "Issue · updated 3d ago" and the
    /// slot's value as a pill in its label's color (its tooltip the full label). The badge's words and the pill's color
    /// are what the old Slot, State, Type and Updated rows said.
    private func facts(_ model: WorkItemDetailModel) -> some View {
        PillFlowLayout(spacing: 8, lineSpacing: 6) {
            StatusBadge(
                text: model.state, symbol: model.workItem.state == .opened ? "circle.dotted" : "checkmark.circle",
                tint: model.workItem.state == .opened ? MergeRequestStatus.Color.green.swiftUI : .secondary)
            Text(verbatim: "\(model.type) · updated \(model.updated)")
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
            if let slot = model.slotLabel {
                LabelPill(label: slot, style: .value)
            }
            if let eggLine = model.eggLine {
                Text(verbatim: eggLine)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func related(_ related: WorkItemDetailModel.Related) -> some View {
        switch related {
        case .rows(let rows):
            ForEach(rows) { RelatedMergeRequestRowView(row: $0, actions: actions) }
        case .none:
            note(WorkItemDetailModel.noMergeRequests)
        case .loading:
            // A small spinner in the part still loading, never over the pane (OD-01).
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .unknown:
            note(WorkItemDetailModel.mergeRequestsUnknown)
        case .epic:
            note(WorkItemDetailModel.epicNote)
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
    }
}

/// A related merge request: its state's symbol, the title wrapping, "!14 · open", as a link to the MR; greyed when its
/// title has Team's ignored prefix (WI-05); a trailing "Show in Merge Requests" while the Merge Requests store has it.
private struct RelatedMergeRequestRowView: View {
    let row: RelatedMergeRequestRow
    let actions: GitLabSectionActions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Link(destination: row.mergeRequest.webURL) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: row.symbol)
                        .foregroundStyle(row.isSymbolSecondary || row.isIgnored ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .frame(width: SectionRowMetrics.symbolColumn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.mergeRequest.title)
                            .foregroundStyle(row.isIgnored ? AnyShapeStyle(.secondary) : AnyShapeStyle(.link))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: row.reference)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            if row.showsInMergeRequests {
                Button("Show in Merge Requests") { actions.showInMergeRequests(row.id) }
                    .controlSize(.small)
            }
        }
        .contextMenu {
            if row.showsInMergeRequests {
                Button("Show in Merge Requests") { actions.showInMergeRequests(row.id) }
                Divider()
            }
            Button(row.openTitle) { actions.open(row.id) }
            Divider()
            Button("Copy Link") { actions.copy(row.id) }
        }
    }
}
