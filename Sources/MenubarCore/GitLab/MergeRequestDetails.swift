import Foundation
import Observation

/// What GitLab knows of one merge request beyond the list: its approvals, its unresolved threads and its head
/// pipeline with the jobs (MR-06 to MR-08). Read only.
public struct MergeRequestDetails: Codable, Hashable, Sendable {
    public var approvals: Approvals
    /// the threads that can be resolved and aren't, oldest first, among the first discussions GitLab sent
    public var threads: [ReviewThread]
    /// how many resolvable threads are resolved, among the same discussions
    public var resolvedThreadCount: Int
    /// the resolved threads themselves, oldest first, which the Discussion card folds to one line each
    public var resolvedThreads: [ReviewThread]
    /// whether GitLab has more discussions than were asked for, so ``threads`` may miss some
    public var hasMoreDiscussions: Bool
    /// the head pipeline; `nil` without one
    public var pipeline: Pipeline?
    /// who reviewed and when, for "Re-request Review" (MR-09); `nil` when GitLab didn't answer that request
    public var reviews: MergeRequestReviews?
    /// whether the threads are in: the store asks the approvals and the pipeline first, and the discussions apart, so
    /// the top cards don't wait for them (OD-07); `false` while only the first part is there
    public var discussionsLoaded = true

    public init(
        approvals: Approvals, threads: [ReviewThread] = [], resolvedThreadCount: Int = 0, hasMoreDiscussions: Bool = false,
        resolvedThreads: [ReviewThread] = [], pipeline: Pipeline? = nil, reviews: MergeRequestReviews? = nil
    ) {
        self.resolvedThreads = resolvedThreads
        self.reviews = reviews
        self.approvals = approvals
        self.threads = threads
        self.resolvedThreadCount = resolvedThreadCount
        self.hasMoreDiscussions = hasMoreDiscussions
        self.pipeline = pipeline
    }

    // MARK: - Approvals

    /// Who approved, how many approvals are needed and the approval rules (MR-06).
    ///
    /// Approval rules are a paid GitLab feature: without them, only the people who approved and the approvals left are
    /// known, and ``rules`` is empty.
    public struct Approvals: Codable, Hashable, Sendable {
        public var approvedBy: [MergeRequest.Person]
        /// how many approvals the merge request needs in all; `nil` when GitLab doesn't say
        public var required: Int?
        public var rules: [Rule]

        public init(approvedBy: [MergeRequest.Person] = [], required: Int? = nil, rules: [Rule] = []) {
            self.approvedBy = approvedBy
            self.required = required
            self.rules = rules
        }

        /// "1 of 2 approvals", "2 approvals" without a requirement, "No approvals yet", "No approvals required"
        public var summary: String {
            let count = approvedBy.count
            guard let required, required > 0 else {
                if required == 0, count == 0 {
                    return "No approvals required"
                }
                return count == 0 ? "No approvals yet" : "\(count) \(count == 1 ? "approval" : "approvals")"
            }
            return "\(count) of \(required) \(required == 1 ? "approval" : "approvals")"
        }

        /// whether the merge request has all the approvals it needs; `nil` when that isn't known
        public var isSatisfied: Bool? {
            if !rules.isEmpty {
                return rules.allSatisfy(\.isSatisfied)
            }
            return required.map { approvedBy.count >= $0 }
        }
    }

    /// One approval rule: who has to approve and whether that is done.
    public struct Rule: Codable, Hashable, Sendable, Identifiable {
        public var name: String
        /// how many approvals the rule needs
        public var required: Int
        public var approvedBy: [MergeRequest.Person]
        /// GitLab's verdict on the rule
        public var isSatisfied: Bool

        public init(name: String, required: Int, approvedBy: [MergeRequest.Person] = [], isSatisfied: Bool) {
            self.name = name
            self.required = required
            self.approvedBy = approvedBy
            self.isSatisfied = isSatisfied
        }

        public var id: String { name }
    }

    // MARK: - Threads

    /// An unresolved thread: its first note and the replies to it (MR-07).
    public struct ReviewThread: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        /// who started the thread; `nil` for a deleted user
        public var author: MergeRequest.Person?
        /// the start of the note as plain text, never markup
        public var excerpt: String
        /// the file, and the line when there is one, of a note on the diff: `src/App.swift:42`; `nil` for a plain
        /// comment
        public var location: String?
        /// the note's page, which opens it in the browser
        public var url: URL?
        /// the first note as written, in Markdown; empty when only ``excerpt`` is known
        public var body: String
        /// when the first note was written
        public var createdAt: Date?
        /// the replies, oldest first, system notes left out
        public var replies: [ThreadNote]
        /// whether GitLab has more replies than were asked for
        public var hasMoreReplies: Bool

        public init(
            id: String, author: MergeRequest.Person?, excerpt: String, location: String? = nil, url: URL? = nil,
            body: String = "", createdAt: Date? = nil, replies: [ThreadNote] = [], hasMoreReplies: Bool = false
        ) {
            self.id = id
            self.author = author
            self.excerpt = excerpt
            self.location = location
            self.url = url
            self.body = body
            self.createdAt = createdAt
            self.replies = replies
            self.hasMoreReplies = hasMoreReplies
        }

        /// the thread as the shared thread view draws it
        public var comment: CommentThread { comment(isResolved: false) }

        /// the thread as the shared thread view draws it, folded when it is resolved
        public func comment(isResolved: Bool) -> CommentThread {
            CommentThread(
                id: id,
                first: ThreadNote(id: id, author: author, body: body.isEmpty ? excerpt : body, createdAt: createdAt, url: url),
                replies: replies, hasMoreReplies: hasMoreReplies, location: location, isResolved: isResolved)
        }
    }

    // MARK: - The pipeline

    /// The head pipeline with its jobs, by stage (MR-08).
    public struct Pipeline: Codable, Hashable, Sendable {
        public var status: MergeRequest.PipelineStatus?
        /// the pipeline's page
        public var url: URL?
        public var stages: [Stage]

        public init(status: MergeRequest.PipelineStatus?, url: URL?, stages: [Stage]) {
            self.status = status
            self.url = url
            self.stages = stages
        }

        /// every job, in stage order
        public var jobs: [Job] { stages.flatMap(\.jobs) }

        /// The jobs that deserve a look first: the failed ones, then the running ones, each group in stage order.
        public var needAttention: [Job] {
            let jobs = jobs
            return jobs.filter { $0.state == .failed } + jobs.filter { $0.state == .running }
        }
    }

    /// A pipeline stage and its jobs.
    public struct Stage: Codable, Hashable, Sendable, Identifiable {
        public var name: String
        public var jobs: [Job]

        public init(name: String, jobs: [Job]) {
            self.name = name
            self.jobs = jobs
        }

        public var id: String { name }

        /// The stage's state, as its worst job says: failed, else running, else waiting, else passed.
        public var state: Job.State {
            for state in [Job.State.failed, .running, .waiting, .canceled] where jobs.contains(where: { $0.state == state }) {
                return state
            }
            return jobs.isEmpty || jobs.allSatisfy({ $0.state == .skipped }) ? .skipped : .passed
        }
    }

    /// One job of a pipeline.
    public struct Job: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var stage: String
        public var state: State
        /// the job's page
        public var url: URL?

        public init(id: String, name: String, stage: String, state: State, url: URL? = nil) {
            self.id = id
            self.name = name
            self.stage = stage
            self.state = state
            self.url = url
        }

        /// What a job is doing, in the few states the detail tells apart.
        public enum State: String, Codable, Hashable, Sendable {
            case failed
            case running
            /// created, pending, scheduled, manual: not started
            case waiting
            case passed
            case canceled
            case skipped

            /// Returns the state of GitLab's `CiJobStatus`.
            ///
            /// - Parameter status: GitLab's value, like `WAITING_FOR_RESOURCE`
            public init(gitLabStatus status: String) {
                switch status.uppercased() {
                case "FAILED": self = .failed
                case "RUNNING", "CANCELING": self = .running
                case "SUCCESS": self = .passed
                case "CANCELED": self = .canceled
                case "SKIPPED": self = .skipped
                default: self = .waiting
                }
            }
        }
    }
}

// MARK: - The operation

/// Which part of the details to ask for: the store asks the approvals and the pipeline (``top``) apart from the
/// discussions, which are the slow, big part, so the top cards fill first (OD-07, Task 7.06: one query of 133 KB took
/// 3.5 s and every card waited for it).
enum MergeRequestDetailsPart: Sendable {
    case all
    /// the approvals and the head pipeline
    case top
    /// the discussions with their notes
    case discussions
}

/// How much of the details to ask for. Approval rules and the approvals left belong to a paid GitLab; a GitLab without
/// them answers a query that names them with a GraphQL error and no data.
enum MergeRequestDetailsLevel: Sendable {
    case full
    /// the people who approved, without the rules
    case basic
}

extension GitLabOperation where Value == MergeRequestDetails {
    /// The details of a merge request, in one request, with `first:` limits so a huge merge request stays small: 100
    /// discussions (up to 50 notes each, for the replies), 20 stages with 50 jobs each (MR-06 to MR-08).
    ///
    /// The query follows GitLab's GraphQL reference (`mergeRequest(iid:)`, `approvalState`, `approvedBy`, `discussions`,
    /// `headPipeline`); it hasn't been run against a real GitLab by the author.
    ///
    /// - Parameters:
    ///   - source: the merge request
    ///   - level: how much to ask for
    ///   - part: which part: all of it, the approvals and the pipeline, or the discussions
    /// - Returns: the operation, or `nil` for a reference without a path or an iid. An answer without the merge request
    ///   (gone, or not visible to the token) is a failure.
    static func details(
        of source: DescriptionSource, level: MergeRequestDetailsLevel = .full, part: MergeRequestDetailsPart = .all
    ) -> GitLabOperation? {
        guard let (path, iid) = source.pathAndIID else {
            return nil
        }
        let approvals =
            switch level {
            case .full:
                """
                approvalsRequired
                      approvalsLeft
                      approvedBy { nodes { username name } }
                      approvalState { rules { name approvalsRequired approved approvedBy { nodes { username name } } } }
                """
            case .basic:
                "approvedBy { nodes { username name } }"
            }
        let base = source.webURL
        let discussions = """
                      discussions(first: 100) {
                        pageInfo { hasNextPage }
                        nodes {
                          id
                          resolvable
                          resolved
                          notes(first: 50) {
                            pageInfo { hasNextPage }
                            nodes {
                              id url body createdAt system author { username name }
                              position { filePath oldPath newPath oldLine newLine }
                            }
                          }
                        }
                      }
            """
        let pipeline = """
                      headPipeline {
                        status
                        detailedStatus { detailsPath }
                        stages(first: 20) {
                          nodes { name jobs(first: 50) { nodes { id name status detailedStatus { detailsPath } } } }
                        }
                      }
            """
        let (name, fields) =
            switch part {
            case .all: ("MergeRequestDetails", [approvals, discussions, pipeline])
            case .top: ("MergeRequestDetails", [approvals, pipeline])
            case .discussions: ("MergeRequestDiscussions", [discussions])
            }
        return GitLabOperation(
            name: name,
            query: """
                query \(name)($path: ID!, $iid: String!) {
                  project(fullPath: $path) {
                    mergeRequest(iid: $iid) {
                      \(fields.joined(separator: "\n"))
                    }
                  }
                }
                """,
            variables: .object([("path", .string(path)), ("iid", .string(iid))]),
            decode: { body in
                let project = try GraphQLAnswer<MergeRequestDetailsShape>.value(of: body).project
                guard let mergeRequest = project?.mergeRequest else {
                    throw DecodingError.valueNotFound(
                        MergeRequestDetails.self, .init(codingPath: [], debugDescription: "no merge request"))
                }
                return mergeRequest.details(base: base)
            })
    }
}

extension MergeRequestDetails {
    /// Takes the threads of other details, as the discussions' own answer brings them (OD-07).
    mutating func adoptDiscussions(of other: MergeRequestDetails?) {
        guard let other else {
            return
        }
        threads = other.threads
        resolvedThreads = other.resolvedThreads
        resolvedThreadCount = other.resolvedThreadCount
        hasMoreDiscussions = other.hasMoreDiscussions
        discussionsLoaded = other.discussionsLoaded
    }
}

extension DetailKind where Value == MergeRequestDetails {
    /// a merge request's approvals, threads, pipeline and reviews (OD-07)
    public static var mergeRequestDetails: DetailKind { DetailKind("merge-request-details") }
}

/// The shape of the answer, and the step from it to the values.
struct MergeRequestDetailsShape: Decodable {
    var project: Project?

    struct Project: Decodable {
        var mergeRequest: Node?
    }

    struct User: Decodable {
        var username: String
        var name: String?

        var person: MergeRequest.Person { MergeRequest.Person(username: username, name: name ?? "") }
    }

    /// the people of a `UserCoreConnection`, or the connection missing from the answer
    struct Users: Decodable {
        var nodes: [User]?
    }

    struct Node: Decodable {
        var approvalsRequired: Int?
        var approvalsLeft: Int?
        var approvedBy: Users?
        var approvalState: ApprovalState?
        var discussions: Discussions?
        var headPipeline: Pipeline?
    }

    struct ApprovalState: Decodable {
        var rules: [Rule]?

        struct Rule: Decodable {
            var name: String?
            var approvalsRequired: Int?
            var approved: Bool?
            var approvedBy: Users?
        }
    }

    struct Discussions: Decodable {
        var pageInfo: PageInfo?
        var nodes: Nodes<Discussion>

        struct PageInfo: Decodable {
            var hasNextPage: Bool?
        }

        private enum Key: String, CodingKey {
            case pageInfo
        }

        // The connection's `nodes` are read from the same object as `pageInfo`.
        init(from decoder: any Decoder) throws {
            pageInfo = try decoder.container(keyedBy: Key.self).decodeIfPresent(PageInfo.self, forKey: .pageInfo)
            nodes = try Nodes(from: decoder)
        }
    }

    struct Discussion: Decodable {
        var id: String
        var resolvable: Bool?
        var resolved: Bool?
        var notes: ConnectionPage<Note>?

        struct Note: Decodable {
            var id: String?
            var url: String?
            var body: String?
            var createdAt: Date?
            var system: Bool?
            var author: User?
            var position: Position?
        }

        struct Position: Decodable {
            var filePath: String?
            var oldPath: String?
            var newPath: String?
            var oldLine: Int?
            var newLine: Int?
        }
    }

    struct Pipeline: Decodable {
        var status: String?
        var detailedStatus: DetailedStatus?
        var stages: Nodes<Stage>?
    }

    struct DetailedStatus: Decodable {
        var detailsPath: String?
    }

    struct Stage: Decodable {
        var name: String
        var jobs: Nodes<Job>?
    }

    struct Job: Decodable {
        var id: String?
        var name: String
        var status: String?
        var detailedStatus: DetailedStatus?
    }
}

extension MergeRequestDetailsShape.Node {
    /// Returns the details this answer holds.
    ///
    /// - Parameter base: the merge request's page, which the relative paths of the pipeline and its jobs resolve against
    func details(base: URL) -> MergeRequestDetails {
        let approvedBy = (approvedBy?.nodes ?? []).map(\.person)
        let rules = (approvalState?.rules ?? []).map { rule in
            MergeRequestDetails.Rule(
                name: rule.name ?? "", required: rule.approvalsRequired ?? 0,
                approvedBy: (rule.approvedBy?.nodes ?? []).map(\.person), isSatisfied: rule.approved ?? false)
        }
        // The total is what GitLab says it needs, else what is done plus what is left.
        let required = approvalsRequired ?? approvalsLeft.map { approvedBy.count + $0 }
        let threads = (discussions?.nodes.nodes ?? [])
            .filter { $0.resolvable == true && $0.resolved != true }
            .map { $0.thread(base: base) }
        let resolvedThreads = (discussions?.nodes.nodes ?? [])
            .filter { $0.resolvable == true && $0.resolved == true }
            .map { $0.thread(base: base) }
        return MergeRequestDetails(
            approvals: .init(approvedBy: approvedBy, required: required, rules: rules),
            threads: threads,
            resolvedThreadCount: resolvedThreads.count,
            hasMoreDiscussions: discussions?.pageInfo?.hasNextPage ?? false,
            resolvedThreads: resolvedThreads,
            pipeline: headPipeline.map { pipeline in
                MergeRequestDetails.Pipeline(
                    status: pipeline.status.map(MergeRequest.PipelineStatus.init(rawValue:)),
                    url: Self.webURL(pipeline.detailedStatus?.detailsPath, base: base),
                    stages: (pipeline.stages?.nodes ?? []).map { stage in
                        MergeRequestDetails.Stage(
                            name: stage.name,
                            jobs: (stage.jobs?.nodes ?? []).map { job in
                                MergeRequestDetails.Job(
                                    id: job.id ?? "\(stage.name)/\(job.name)", name: job.name, stage: stage.name,
                                    state: .init(gitLabStatus: job.status ?? ""),
                                    url: Self.webURL(job.detailedStatus?.detailsPath, base: base))
                            })
                    })
            })
    }

    /// Returns a page GitLab named by a path or a URL, if it is a web address.
    static func webURL(_ text: String?, base: URL) -> URL? {
        guard let text, !text.isEmpty, let url = URL(string: text, relativeTo: base)?.absoluteURL,
            url.scheme == "http" || url.scheme == "https"
        else {
            return nil
        }
        return url
    }
}

extension MergeRequestDetailsShape.Discussion {
    /// Returns the thread: its first note's author, text and start, the place on the diff and the note's page, and the
    /// replies after it.
    func thread(base: URL) -> MergeRequestDetails.ReviewThread {
        // A resolvable thread starts with a user's note; system notes ("resolved all threads") are no replies.
        let all = notes?.nodes ?? []
        let note = all.first
        let replies = all.dropFirst().compactMap { reply -> ThreadNote? in
            guard reply.system != true else {
                return nil
            }
            return ThreadNote(
                id: reply.id ?? UUID().uuidString, author: reply.author?.person, body: reply.body ?? "",
                createdAt: reply.createdAt, url: NoteShape.noteURL(reply.url, id: reply.id, base: base))
        }
        var location: String?
        if let position = note?.position, let file = position.filePath ?? position.newPath ?? position.oldPath, !file.isEmpty {
            location = (position.newLine ?? position.oldLine).map { "\(file):\($0)" } ?? file
        }
        // Without a `url`, the page of the merge request jumps to the note by its number.
        let url = NoteShape.noteURL(note?.url, id: note?.id, base: base)
        return MergeRequestDetails.ReviewThread(
            id: id, author: note?.author.map { MergeRequest.Person(username: $0.username, name: $0.name ?? "") },
            excerpt: PlainText.excerpt(of: note?.body ?? ""), location: location, url: url, body: note?.body ?? "",
            createdAt: note?.createdAt, replies: replies, hasMoreReplies: notes?.hasNextPage ?? false)
    }
}

// MARK: - Plain text

/// Markdown reduced to a line of plain text, for the quotes of the detail: never rendered, never HTML.
enum PlainText {
    /// Returns the start of a Markdown text as one line of plain text.
    ///
    /// Code blocks, quote marks, headings, list bullets, emphasis marks and the URLs of links go; the words stay. HTML
    /// tags and entities aren't interpreted: they stay as text.
    ///
    /// - Parameters:
    ///   - markdown: the text
    ///   - limit: the most characters, cut at a word with an ellipsis
    /// - Returns: the text on one line
    static func excerpt(of markdown: String, limit: Int = 200) -> String {
        var lines: [String] = []
        var inFence = false
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence {
                // Code isn't prose: a quote of a note starts with the words.
                continue
            }
            // Quote marks, headings and bullets lead a line.
            line = line.replacingOccurrences(of: #"^(>\s*)+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^(#{1,6}\s+|[-*+]\s+(\[[ xX]\]\s+)?|\d+\.\s+)"#, with: "", options: .regularExpression)
            // An image or a link keeps its text.
            line = line.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"(\*\*|__|~~|`|\*)"#, with: "", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        let text = lines.joined(separator: " ")
        guard text.count > limit else {
            return text
        }
        let cut = text.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}

// MARK: - The store

/// What the detail knows of a merge request's details (MR-06 to MR-08).
public struct MergeRequestDetailsState: Hashable, Sendable {
    /// as last loaded, maybe for an older update of the merge request; `nil` before an answer
    public var details: MergeRequestDetails?
    /// whether ``details`` belongs to the merge request's last update
    public var isCurrent: Bool
    /// whether the last request failed
    public var failed: Bool

    public init(details: MergeRequestDetails?, isCurrent: Bool, failed: Bool = false) {
        self.details = details
        self.isCurrent = isCurrent
        self.failed = failed
    }

    /// asked, with no answer yet
    public static let loading = MergeRequestDetailsState(details: nil, isCurrent: false)

    /// Returns the answer for the merge request's last update.
    public static func loaded(_ details: MergeRequestDetails) -> MergeRequestDetailsState {
        MergeRequestDetailsState(details: details, isCurrent: true)
    }
}

/// The details of the merge requests the user selected, loaded one at a time when a merge request is selected, never
/// with the list (MR-06 to MR-08).
///
/// Details are kept per merge request, in memory, for the merge request's last update: selecting it again asks nothing
/// until the list brings a newer `updatedAt`. After a failed request, the next selection asks again; while a newer
/// update loads or fails, the older details stay.
@Observable @MainActor
public final class MergeRequestDetailsStore {
    private struct Entry {
        var details: MergeRequestDetails?
        /// the merge request's `updatedAt` that `details` belongs to
        var detailsUpdatedAt: Date?
        var isLoading = false
        var failed = false
        /// whether `details` came from the disk and weren't asked this launch (OD-07)
        var fromDisk = false
    }

    private let entries = ObservedEntries<String, Entry>()
    /// whether the stored token can write, as GitLab's answer to ``checkWriteAccess()`` says (MR-09)
    public private(set) var writeAccess: WriteAccess = .unknown
    /// the fingerprint of the token ``writeAccess`` was asked with: a token's scopes never change, so it is asked once
    /// per token (Task 7.06: it was asked each time the reviewers showed)
    @ObservationIgnored private var writeAccessToken: String?
    /// the levels this GitLab answers: once the full query failed for a missing field, the basic one is asked first
    /// (Task 7.06: every selection asked the reviews twice). Reset at each launch, so a GitLab update is picked up.
    @ObservationIgnored private var levels = Levels()
    @ObservationIgnored private let services: GitLabServices
    /// the merge state and the Merge card's writes (MR-16); a write loads these details again
    public let merge: MergeRequestMergeStore

    private struct Levels: Sendable {
        var details: MergeRequestDetailsLevel = .full
        var reviews: MergeRequestReviewsLevel = .full
    }

    /// - Parameter services: the transport, the token and the team values; the logs record the requests
    public init(services: GitLabServices) {
        self.services = services
        merge = MergeRequestMergeStore(services: services)
        merge.afterWrite = { [weak self] mergeRequest in await self?.load(mergeRequest, force: true) }
    }

    /// Returns what is known of a merge request's details.
    ///
    /// - Parameter mergeRequest: the merge request
    public func state(of mergeRequest: MergeRequest) -> MergeRequestDetailsState {
        guard let entry = entries[mergeRequest.reference] else {
            return .loading
        }
        let isCurrent = entry.detailsUpdatedAt.map { $0 >= mergeRequest.updatedAt } ?? false
        return MergeRequestDetailsState(
            details: entry.details, isCurrent: entry.details != nil && isCurrent, failed: entry.failed && !entry.isLoading)
    }

    /// Loads a merge request's details, when it is selected: unless they are loading already, or were loaded for its
    /// last update.
    ///
    /// Without a GitLab token or the team values it asks nothing and fails quietly. A GitLab that doesn't know the
    /// approval rules answers with a GraphQL error, and the details are asked again without them. Cancelling the calling
    /// task doesn't cancel the request.
    ///
    /// The approvals and the pipeline, the discussions and the reviews are three requests at once; the first part shows
    /// as soon as it is there. Details kept on disk show at once and are asked again once per launch (OD-07).
    ///
    /// - Parameters:
    ///   - mergeRequest: the selected merge request
    ///   - force: loads again although the details belong to the merge request's last update, as after a re-request
    public func load(_ mergeRequest: MergeRequest, force: Bool = false) async {
        let key = mergeRequest.reference
        var entry = entries[key] ?? Entry()
        // The copy on disk shows at once; it is asked again below (OD-07).
        if entries[key] == nil, let kept = services.details?.load(.mergeRequestDetails, key: key) {
            entry.details = kept.value
            entry.detailsUpdatedAt = kept.updatedAt
            entry.fromDisk = true
            entries[key] = entry
        }
        if entry.isLoading || (!force && !entry.fromDisk && state(of: mergeRequest).isCurrent) {
            return
        }
        let source = DescriptionSource(mergeRequest)
        guard let full = GitLabOperation.details(of: source, part: .top),
            let basic = GitLabOperation.details(of: source, level: .basic, part: .top),
            let discussionsOperation = GitLabOperation.details(of: source, part: .discussions)
        else {
            entry.failed = true
            entries[key] = entry
            return
        }
        entry.isLoading = true
        entry.failed = false
        entries[key] = entry
        // Tasks of their own, which a new selection doesn't cancel: the answers are kept for when the merge request is
        // selected again. The approvals and the pipeline, the discussions and the reviews are asked at once, and the
        // first part shows as soon as it is there (OD-07).
        let services = services
        let start = levels
        guard let client = await Task(operation: { try? await services.session().get().client }).value else {
            finish(key, updatedAt: mergeRequest.updatedAt, details: nil)
            return
        }
        let discussionsTask = Task { try? await client.send(discussionsOperation) }
        let reviewsTask = Task { await client.reviews(of: source, startingAt: start.reviews) }
        let top = await Task { () -> (MergeRequestDetails, MergeRequestDetailsLevel)? in
            do {
                return (try await client.send(start.details == .full ? full : basic), start.details)
            } catch let error as GitLabError {
                guard start.details == .full, case .graphQLErrors = error.problem, let answer = try? await client.send(basic) else {
                    return nil
                }
                return (answer, .basic)
            } catch {
                return nil
            }
        }.value
        guard let top else {
            discussionsTask.cancel()
            reviewsTask.cancel()
            finish(key, updatedAt: mergeRequest.updatedAt, details: nil)
            return
        }
        var details = top.0
        levels.details = top.1
        // Until the discussions are there, the older threads stay, or the card waits with its skeleton.
        let older = entries[key]?.details
        details.reviews = older?.reviews
        details.adoptDiscussions(of: older)
        if older == nil {
            details.discussionsLoaded = false
        }
        entry = entries[key] ?? Entry()
        entry.details = details
        entry.detailsUpdatedAt = mergeRequest.updatedAt
        entries[key] = entry

        let discussions = await discussionsTask.value
        let reviews = await reviewsTask.value
        if let discussions {
            details.adoptDiscussions(of: discussions)
        }
        details.discussionsLoaded = true
        if let reviews {
            details.reviews = reviews.reviews
            levels.reviews = reviews.level
        }
        finish(key, updatedAt: mergeRequest.updatedAt, details: details)
        if discussions != nil {
            services.details?.save(details, updatedAt: mergeRequest.updatedAt, as: .mergeRequestDetails, key: key)
        }
    }

    /// Ends a load: keeps the details for the merge request's update, or marks it failed and keeps what was shown.
    private func finish(_ key: String, updatedAt: Date, details: MergeRequestDetails?) {
        var entry = entries[key] ?? Entry()
        entry.isLoading = false
        if let details {
            entry.details = details
            entry.detailsUpdatedAt = updatedAt
            entry.fromDisk = false
        } else {
            entry.failed = true
        }
        entries[key] = entry
    }

    /// Asks GitLab which scopes the stored token has, so the re-request buttons know before a click whether the token
    /// can write. Without a token, or when GitLab doesn't say, the access stays unknown and nothing is blocked.
    ///
    /// GitLab is asked once per token: the answer is kept until the stored token changes.
    public func checkWriteAccess() async {
        let services = services
        let known = writeAccess == .unknown ? nil : writeAccessToken
        let answer = await Task { () -> (WriteAccess, String?)? in
            guard let token = try? await services.tokens.token(.gitlab), !token.isEmpty else {
                return (.unknown, nil)
            }
            let fingerprint = GitLabUser.fingerprint(of: token)
            if fingerprint == known {
                return nil
            }
            guard let client = try? await services.session().get().client,
                let scopes = try? await client.tokenScopes()
            else {
                return (.unknown, nil)
            }
            return (WriteAccess(scopes: scopes), fingerprint)
        }.value
        if let (access, fingerprint) = answer {
            writeAccess = access
            writeAccessToken = fingerprint
        }
    }

    /// Asks reviewers for a new review, after a click: one request each, then loads the merge request's details again.
    ///
    /// Nothing is sent again after a failure, and a refusal for the token's scope ends the run. Cancelling the calling
    /// task doesn't cancel the requests.
    ///
    /// - Parameters:
    ///   - reviewers: who to ask
    ///   - mergeRequest: the merge request
    /// - Returns: who was asked and who failed; every reviewer failed without a token or the team values
    public func reRequest(_ reviewers: [MergeRequestReviews.Reviewer], of mergeRequest: MergeRequest) async -> ReReviewOutcome {
        let services = services
        let source = DescriptionSource(mergeRequest)
        let outcome = await Task { () -> ReReviewOutcome in
            switch await services.session() {
            case .success(let session):
                return await session.client.reRequest(reviewers, of: source)
            case .failure(let error):
                return ReReviewOutcome(
                    failures: reviewers.map { .init(reviewer: $0, message: error.description) },
                    needsToken: error.problem == .noToken(.gitLab))
            }
        }.value
        if !outcome.sent.isEmpty {
            await load(mergeRequest, force: true)
        }
        return outcome
    }
}
