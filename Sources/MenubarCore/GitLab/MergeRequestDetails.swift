import Foundation
import Observation

/// What GitLab knows of one merge request beyond the list: its approvals, its unresolved threads and its head
/// pipeline with the jobs (MR-06 to MR-08). Read only.
public struct MergeRequestDetails: Hashable, Sendable {
    public var approvals: Approvals
    /// the threads that can be resolved and aren't, oldest first, among the first discussions GitLab sent
    public var threads: [ReviewThread]
    /// how many resolvable threads are resolved, among the same discussions
    public var resolvedThreadCount: Int
    /// whether GitLab has more discussions than were asked for, so ``threads`` may miss some
    public var hasMoreDiscussions: Bool
    /// the head pipeline; `nil` without one
    public var pipeline: Pipeline?
    /// who reviewed and when, for "Re-request Review" (MR-09); `nil` when GitLab didn't answer that request
    public var reviews: MergeRequestReviews?

    public init(
        approvals: Approvals, threads: [ReviewThread] = [], resolvedThreadCount: Int = 0, hasMoreDiscussions: Bool = false,
        pipeline: Pipeline? = nil, reviews: MergeRequestReviews? = nil
    ) {
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
    public struct Approvals: Hashable, Sendable {
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
    public struct Rule: Hashable, Sendable, Identifiable {
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

    /// An unresolved thread: its first note (MR-07).
    public struct ReviewThread: Hashable, Sendable, Identifiable {
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

        public init(id: String, author: MergeRequest.Person?, excerpt: String, location: String? = nil, url: URL? = nil) {
            self.id = id
            self.author = author
            self.excerpt = excerpt
            self.location = location
            self.url = url
        }
    }

    // MARK: - The pipeline

    /// The head pipeline with its jobs, by stage (MR-08).
    public struct Pipeline: Hashable, Sendable {
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
    public struct Stage: Hashable, Sendable, Identifiable {
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
    public struct Job: Hashable, Sendable, Identifiable {
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
        public enum State: Hashable, Sendable {
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

/// How much of the details to ask for. Approval rules and the approvals left belong to a paid GitLab; a GitLab without
/// them answers a query that names them with a GraphQL error and no data.
enum MergeRequestDetailsLevel: Sendable {
    case full
    /// the people who approved, without the rules
    case basic
}

extension GitLabOperation where Value == MergeRequestDetails {
    /// The details of a merge request, in one request, with `first:` limits so a huge merge request stays small: 100
    /// discussions (a first note each), 20 stages with 50 jobs each (MR-06 to MR-08).
    ///
    /// The query follows GitLab's GraphQL reference (`mergeRequest(iid:)`, `approvalState`, `approvedBy`, `discussions`,
    /// `headPipeline`); it hasn't been run against a real GitLab by the author.
    ///
    /// - Parameters:
    ///   - source: the merge request
    ///   - level: how much to ask for
    /// - Returns: the operation, or `nil` for a reference without a path or an iid. An answer without the merge request
    ///   (gone, or not visible to the token) is a failure.
    static func details(of source: DescriptionSource, level: MergeRequestDetailsLevel = .full) -> GitLabOperation? {
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
        return GitLabOperation(
            name: "MergeRequestDetails",
            query: """
                query MergeRequestDetails($path: ID!, $iid: String!) {
                  project(fullPath: $path) {
                    mergeRequest(iid: $iid) {
                      \(approvals)
                      discussions(first: 100) {
                        pageInfo { hasNextPage }
                        nodes {
                          id
                          resolvable
                          resolved
                          notes(first: 1) {
                            nodes { id url body author { username name } position { filePath oldPath newPath oldLine newLine } }
                          }
                        }
                      }
                      headPipeline {
                        status
                        detailedStatus { detailsPath }
                        stages(first: 20) {
                          nodes { name jobs(first: 50) { nodes { id name status detailedStatus { detailsPath } } } }
                        }
                      }
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
        var notes: Nodes<Note>?

        struct Note: Decodable {
            var id: String?
            var url: String?
            var body: String?
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
        return MergeRequestDetails(
            approvals: .init(approvedBy: approvedBy, required: required, rules: rules),
            threads: threads,
            resolvedThreadCount: (discussions?.nodes.nodes ?? []).filter { $0.resolvable == true && $0.resolved == true }.count,
            hasMoreDiscussions: discussions?.pageInfo?.hasNextPage ?? false,
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
    /// Returns the thread: its first note's author and start, the place on the diff and the note's page.
    func thread(base: URL) -> MergeRequestDetails.ReviewThread {
        let note = notes?.nodes.first
        var location: String?
        if let position = note?.position, let file = position.filePath ?? position.newPath ?? position.oldPath, !file.isEmpty {
            location = (position.newLine ?? position.oldLine).map { "\(file):\($0)" } ?? file
        }
        // Without a `url`, the page of the merge request jumps to the note by its number.
        let url = MergeRequestDetailsShape.Node.webURL(note?.url, base: base)
            ?? note?.id.flatMap { $0.split(separator: "/").last }.flatMap { number in
                number.allSatisfy(\.isNumber) ? URL(string: base.absoluteString + "#note_" + number) : nil
            }
        return MergeRequestDetails.ReviewThread(
            id: id, author: note?.author.map { MergeRequest.Person(username: $0.username, name: $0.name ?? "") },
            excerpt: PlainText.excerpt(of: note?.body ?? ""), location: location, url: url)
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
    }

    private var entries: [String: Entry] = [:]
    /// whether the stored token can write, as GitLab's answer to ``checkWriteAccess()`` says (MR-09)
    public private(set) var writeAccess: WriteAccess = .unknown
    @ObservationIgnored private let services: GitLabServices

    /// - Parameter services: the transport, the token and the team values; the logs record the requests
    public init(services: GitLabServices) {
        self.services = services
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
    /// - Parameters:
    ///   - mergeRequest: the selected merge request
    ///   - force: loads again although the details belong to the merge request's last update, as after a re-request
    public func load(_ mergeRequest: MergeRequest, force: Bool = false) async {
        let key = mergeRequest.reference
        var entry = entries[key] ?? Entry()
        if entry.isLoading || (!force && state(of: mergeRequest).isCurrent) {
            return
        }
        let source = DescriptionSource(mergeRequest)
        guard let full = GitLabOperation.details(of: source), let basic = GitLabOperation.details(of: source, level: .basic) else {
            entry.failed = true
            entries[key] = entry
            return
        }
        entry.isLoading = true
        entry.failed = false
        entries[key] = entry
        // A task of its own, which a new selection doesn't cancel: the answer is small, and kept for when the merge
        // request is selected again.
        let services = services
        let details = await Task { () -> MergeRequestDetails? in
            guard let client = try? await services.session().get().client else {
                return nil
            }
            var details: MergeRequestDetails
            do {
                details = try await client.send(full)
            } catch let error as GitLabError {
                guard case .graphQLErrors = error.problem, let basic = try? await client.send(basic) else {
                    return nil
                }
                details = basic
            } catch {
                return nil
            }
            // A request of its own: a GitLab that doesn't know its newer fields costs the re-request, not the details.
            details.reviews = await client.reviews(of: source)
            return details
        }.value
        entry = entries[key] ?? Entry()
        entry.isLoading = false
        if let details {
            entry.details = details
            entry.detailsUpdatedAt = mergeRequest.updatedAt
        } else {
            entry.failed = true
        }
        entries[key] = entry
    }
    /// Asks GitLab which scopes the stored token has, so the re-request buttons know before a click whether the token
    /// can write. Without a token, or when GitLab doesn't say, the access stays unknown and nothing is blocked.
    public func checkWriteAccess() async {
        let services = services
        let access = await Task { () -> WriteAccess in
            guard let client = try? await services.session().get().client,
                let scopes = try? await client.tokenScopes()
            else {
                return .unknown
            }
            return WriteAccess(scopes: scopes)
        }.value
        writeAccess = access
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
