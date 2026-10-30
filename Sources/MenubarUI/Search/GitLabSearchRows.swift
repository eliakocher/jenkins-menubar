import MenubarCore
import SwiftUI

/// What the "In GitLab" section of the Merge Requests and Work Items lists shows (WIN-07), as plain values: the direct hit
/// of a reference, the search's state and the rows GitLab found that the list doesn't show.
struct GitLabSearchRows: Equatable, Sendable {
    /// How the search stands, for the lines under the rows.
    enum Status: Equatable, Sendable {
        case loading
        /// searched, and nothing but the list's own rows matched
        case noMatches
        /// a quiet line, GitLab's problem in words
        case failed(String)
        case none
    }

    /// One row: a direct hit, or an item GitLab found.
    struct Row: Equatable, Sendable, Identifiable {
        /// the reference in lowercase
        var id: String
        /// the item's page, which opens in the app (or in the browser with ⌥)
        var url: URL
        /// the full reference, like `group/project#12`, which is a work item row's tag
        var reference: String
        var title: String
        /// "!12 · Open · by Sam Lee · group/project · updated 5m ago"
        var detail: String
        var symbol: String
        /// "Open Merge Request !12 in GitLab"
        var openTitle: String
        var isDirect: Bool
    }

    var rows: [Row] = []
    var status: Status = .none

    /// nothing: no section
    static let hidden = GitLabSearchRows()

    var isShown: Bool { !rows.isEmpty || status != .none }

    func row(url: URL?) -> Row? {
        url.flatMap { url in rows.first { $0.url == url } }
    }

    func row(reference: String?) -> Row? {
        reference.flatMap { reference in rows.first { $0.reference == reference } }
    }

    /// Returns what the section shows for the search field's text.
    ///
    /// - Parameters:
    ///   - kind: the kind of item the list shows
    ///   - text: the search field's text
    ///   - shown: the references of the rows the list shows, which are left out
    ///   - model: the app's model
    ///   - now: the time the ages count from
    /// - Returns: the section's values; ``hidden`` for no search, or when a setup step already says what is missing
    @MainActor
    static func make(kind: GitLabSearchKind, text: String, shown: [String], model: AppModel, now: Date) -> GitLabSearchRows {
        let store = model.gitLabSearch
        let shownReferences = Set(shown.map { $0.lowercased() })
        var result = GitLabSearchRows()
        if case .reference(let route) = store.intent(for: text) {
            let item: (reference: String, short: String, label: String)? =
                switch route {
                case .mergeRequest(let project, let iid): ("\(project)!\(iid)", "!\(iid)", "Merge Request")
                case .workItem(let project, let iid): ("\(project)#\(iid)", "#\(iid)", "Work Item")
                default: nil
                }
            if let item, !shownReferences.contains(item.reference.lowercased()), let url = model.gitLabPage(of: route) {
                let project = String(item.reference.dropLast(item.short.count))
                result.rows.append(
                    Row(
                        id: item.reference.lowercased(), url: url, reference: item.reference, title: "Open \(item.short)",
                        detail: "\(item.label) in \(project)", symbol: "arrow.right.circle",
                        openTitle: "Open \(item.label) \(item.short) in GitLab", isDirect: true))
            }
        }
        switch store.phase(kind: kind, text: text) {
        case .idle:
            break
        case .loading:
            result.status = .loading
        case .loaded(let hits):
            let fresh = GitLabSearchRules.leavingOut(shown: shownReferences, from: hits)
            result.rows += fresh.map { Row($0, now: now) }
            result.status = fresh.isEmpty && result.rows.isEmpty ? .noMatches : .none
        case .failed(let problem):
            // A missing token or team value is a setup step the section shows already.
            if problem != .noToken(.gitLab), problem != .teamValuesMissing {
                result.status = .failed(problem.message)
            }
        }
        return result
    }
}

extension GitLabSearchRows.Row {
    init(_ hit: GitLabSearchHit, now: Date) {
        var parts = [hit.shortReference, hit.isDraft && hit.isOpen ? "Draft" : hit.stateText]
        if let type = hit.type, type != WorkItemType.issue.rawValue {
            parts.append(type.capitalized)
        }
        if !hit.author.isEmpty {
            parts.append("by \(hit.author)")
        }
        parts += [hit.project, "updated \(GitLabText.age(since: hit.updatedAt, now: now)) ago"]
        let isMergeRequest = hit.kind == .mergeRequest
        self.init(
            id: hit.id, url: hit.webURL, reference: hit.reference, title: hit.title, detail: parts.joined(separator: " · "),
            symbol: Self.symbol(of: hit), openTitle: "Open \(isMergeRequest ? "Merge Request" : "Work Item") \(hit.shortReference) in GitLab",
            isDirect: false)
    }

    private static func symbol(of hit: GitLabSearchHit) -> String {
        switch (hit.kind, hit.state) {
        case (.mergeRequest, "merged"): "arrow.triangle.merge"
        case (.mergeRequest, "opened"): "arrow.triangle.pull"
        case (.mergeRequest, _): "xmark.circle"
        case (.workItem, "opened"): "circle.dotted"
        case (.workItem, _): "checkmark.circle"
        }
    }
}

/// The "In GitLab" section of a list: the rows tagged for the list's selection, a spinner while GitLab is asked, and the
/// quiet lines. A click opens a row, as does Return on it.
struct GitLabSearchSection<Tag: Hashable>: View {
    let search: GitLabSearchRows
    /// a row's tag in the list's selection
    let tag: (GitLabSearchRows.Row) -> Tag
    let open: (GitLabSearchRows.Row) -> Void

    var body: some View {
        if search.isShown {
            Section("In GitLab") {
                ForEach(search.rows) { row in
                    GitLabSearchRowContent(row: row)
                        .tag(tag(row))
                        .contentShape(Rectangle())
                        .onTapGesture { open(row) }
                }
                switch search.status {
                case .loading:
                    // GitLab is asked: two rows of bars where its answers will go.
                    SkeletonRows(count: 2, leading: .symbol(column: SectionRowMetrics.symbolColumn))
                case .noMatches:
                    Text("No other matches")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                case .failed(let message):
                    Text(verbatim: message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                case .none:
                    EmptyView()
                }
            }
        }
    }
}

/// A row of the "In GitLab" section, in the look of the list's own rows: the symbol, the title, and the details under it.
struct GitLabSearchRowContent: View {
    let row: GitLabSearchRows.Row
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: row.symbol)
                .foregroundStyle(row.isDirect ? Color.accentColor : Color.secondary)
                .frame(width: SectionRowMetrics.symbolColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.title)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    .help(row.title)
                Text(verbatim: row.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
        }
    }
}
