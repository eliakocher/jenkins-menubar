import Foundation
import Observation

/// What a description belongs to: a merge request or a work item, by the reference GitLab gave it (WIN-02).
public struct DescriptionSource: Hashable, Sendable {
    /// Whose description it is, which picks the query.
    public enum Kind: Hashable, Sendable {
        case mergeRequest
        case workItem
    }

    public var kind: Kind
    /// the full reference, like `group/project!12`, `group/project#31` or `group&12` for an epic
    public var reference: String
    /// the item's page, which the description's relative links and images resolve against
    public var webURL: URL
    /// when the item last changed: a description loaded for an older time is loaded again
    public var updatedAt: Date

    public init(kind: Kind, reference: String, webURL: URL, updatedAt: Date) {
        self.kind = kind
        self.reference = reference
        self.webURL = webURL
        self.updatedAt = updatedAt
    }

    /// - Parameter mergeRequest: the merge request
    public init(_ mergeRequest: MergeRequest) {
        self.init(kind: .mergeRequest, reference: mergeRequest.reference, webURL: mergeRequest.webURL,
                  updatedAt: mergeRequest.updatedAt)
    }

    /// - Parameter workItem: the work item
    public init(_ workItem: WorkItem) {
        self.init(kind: .workItem, reference: workItem.reference, webURL: workItem.webURL, updatedAt: workItem.updatedAt)
    }

    /// the reference's path and iid, split at its last `!`, `#` or `&`; `nil` when either is missing
    var pathAndIID: (path: String, iid: String)? {
        let signs: Set<Character> = kind == .mergeRequest ? ["!"] : ["#", "&"]
        guard let sign = reference.lastIndex(where: signs.contains) else {
            return nil
        }
        let path = String(reference[..<sign])
        let iid = String(reference[reference.index(after: sign)...])
        guard !path.isEmpty, !iid.isEmpty, iid.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return (path, iid)
    }
}

extension GitLabOperation where Value == String {
    /// The description of a merge request or a work item, as GitLab keeps it: Markdown, empty without one (WIN-02).
    ///
    /// A work item's comes from its description widget, asked of its namespace, the project's path, or the group's for
    /// an epic. An answer without the item (gone, or not visible to the token) is a failure.
    ///
    /// - Parameter source: the merge request or work item
    /// - Returns: the operation, or `nil` for a reference without a path or an iid
    public static func description(of source: DescriptionSource) -> GitLabOperation? {
        guard let (path, iid) = source.pathAndIID else {
            return nil
        }
        let variables = GraphQLValue.object([("path", .string(path)), ("iid", .string(iid))])
        switch source.kind {
        case .mergeRequest:
            return GitLabOperation(
                name: "MergeRequestDescription",
                query: """
                    query MergeRequestDescription($path: ID!, $iid: String!) {
                      project(fullPath: $path) { mergeRequest(iid: $iid) { description } }
                    }
                    """,
                variables: variables,
                decode: { body in
                    let project = try GraphQLAnswer<MergeRequestDescriptionShape>.value(of: body).project
                    guard let mergeRequest = project?.mergeRequest else {
                        throw DecodingError.valueNotFound(String.self, .init(codingPath: [], debugDescription: "no merge request"))
                    }
                    return mergeRequest.description ?? ""
                })
        case .workItem:
            return GitLabOperation(
                name: "WorkItemDescription",
                query: """
                    query WorkItemDescription($path: ID!, $iid: String!) {
                      namespace(fullPath: $path) {
                        workItem(iid: $iid) { widgets { ... on WorkItemWidgetDescription { description } } }
                      }
                    }
                    """,
                variables: variables,
                decode: { body in
                    let namespace = try GraphQLAnswer<WorkItemDescriptionShape>.value(of: body).namespace
                    guard let workItem = namespace?.workItem else {
                        throw DecodingError.valueNotFound(String.self, .init(codingPath: [], debugDescription: "no work item"))
                    }
                    // Every other widget answers as an empty object.
                    return workItem.widgets?.lazy.compactMap(\.description).first ?? ""
                })
        }
    }
}

private struct MergeRequestDescriptionShape: Decodable {
    var project: Project?

    struct Project: Decodable {
        var mergeRequest: MergeRequest?
    }

    struct MergeRequest: Decodable {
        var description: String?
    }
}

private struct WorkItemDescriptionShape: Decodable {
    var namespace: Namespace?

    struct Namespace: Decodable {
        var workItem: WorkItem?
    }

    struct WorkItem: Decodable {
        var widgets: [Widget]?
    }

    struct Widget: Decodable {
        var description: String?
    }
}

/// What the detail knows of an item's description (WIN-02).
public struct ItemDescription: Hashable, Sendable {
    /// the Markdown as last loaded, maybe for an older update of the item; `nil` before an answer
    public var text: String?
    /// whether ``text`` belongs to the item's last update
    public var isCurrent: Bool
    /// whether the last request failed
    public var failed: Bool

    public init(text: String?, isCurrent: Bool, failed: Bool = false) {
        self.text = text
        self.isCurrent = isCurrent
        self.failed = failed
    }

    /// asked, with no answer yet
    public static let loading = ItemDescription(text: nil, isCurrent: false)
    /// the request failed, and no older text is kept
    public static let failed = ItemDescription(text: nil, isCurrent: false, failed: true)

    /// Returns the answer for the item's last update.
    ///
    /// - Parameter text: the Markdown; empty when the item has none
    public static func loaded(_ text: String) -> ItemDescription {
        ItemDescription(text: text, isCurrent: true)
    }
}

/// The descriptions of the merge requests and work items the user selected, loaded one at a time when an item is
/// selected, never with the lists (WIN-02).
///
/// A description is kept per item, in memory, for the item's last update: selecting the item again asks nothing until
/// the list brings a newer `updatedAt`. After a failed request, the next selection asks again; while a newer one loads
/// or fails, the older text stays.
@Observable @MainActor
public final class DescriptionsStore {
    /// A description as last loaded, and the request under way.
    private struct Entry {
        var text: String?
        /// the item's `updatedAt` that `text` belongs to
        var textUpdatedAt: Date?
        var isLoading = false
        var failed = false
    }

    private var entries: [String: Entry] = [:]
    @ObservationIgnored private let services: GitLabServices

    /// - Parameter services: the transport, the token and the team values; the logs record the requests
    public init(services: GitLabServices) {
        self.services = services
    }

    /// Returns what is known of an item's description.
    ///
    /// - Parameter source: the item
    /// - Returns: the text when one was loaded, also for an older update, and whether it is current
    public func description(of source: DescriptionSource) -> ItemDescription {
        guard let entry = entries[source.reference] else {
            return .loading
        }
        let isCurrent = entry.textUpdatedAt.map { $0 >= source.updatedAt } ?? false
        return ItemDescription(text: entry.text, isCurrent: entry.text != nil && isCurrent, failed: entry.failed && !entry.isLoading)
    }

    /// Loads an item's description, when it is selected: unless it is loading already, or was loaded for the item's
    /// last update.
    ///
    /// Without a GitLab token or the team values it asks nothing and fails quietly: the detail doesn't show then.
    /// Cancelling the calling task doesn't cancel the request.
    ///
    /// - Parameters:
    ///   - source: the selected item
    ///   - force: loads again although the text belongs to the item's last update, as the window's Reload does
    public func load(_ source: DescriptionSource, force: Bool = false) async {
        let key = source.reference
        var entry = entries[key] ?? Entry()
        if entry.isLoading || (!force && description(of: source).isCurrent) {
            return
        }
        guard let operation = GitLabOperation.description(of: source) else {
            entry.failed = true
            entries[key] = entry
            return
        }
        entry.isLoading = true
        entry.failed = false
        entries[key] = entry
        // A task of its own, which a new selection doesn't cancel: the answer is small, and kept for when the item is
        // selected again.
        let services = services
        let text = await Task {
            try? await services.session().get().client.send(operation)
        }.value
        entry = entries[key] ?? Entry()
        entry.isLoading = false
        if let text {
            entry.text = text
            entry.textUpdatedAt = source.updatedAt
        } else {
            entry.failed = true
        }
        entries[key] = entry
    }
}
