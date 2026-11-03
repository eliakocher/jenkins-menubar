import Foundation

/// One of the user's own to-dos, in the Inbox's "My To-Dos" group (Task 7.03, the user, 2026-11-03: "we should be able
/// to add something manually like a little todo list"). It is kept on this Mac and never goes to GitLab.
public struct MyTodo: Codable, Hashable, Sendable, Identifiable {
    /// a random id, stable for the to-do's life
    public var id: String
    public var title: String
    /// a longer line under the title; empty for none
    public var note: String
    /// when it is due; `nil` for no date
    public var dueDate: Date?
    /// the merge request, work item or build it is about; `nil` for none
    public var link: MyTodoLink?
    public var createdAt: Date
    /// when its checkbox was ticked; `nil` while it is pending
    public var doneAt: Date?
    /// until when it sleeps; `nil` when it isn't snoozed
    public var snoozedUntil: Date?

    public init(
        id: String = UUID().uuidString, title: String, note: String = "", dueDate: Date? = nil, link: MyTodoLink? = nil,
        createdAt: Date, doneAt: Date? = nil, snoozedUntil: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.dueDate = dueDate
        self.link = link
        self.createdAt = createdAt
        self.doneAt = doneAt
        self.snoozedUntil = snoozedUntil
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, note, dueDate, link, createdAt, doneAt, snoozedUntil
    }

    // A file written before a field existed reads with that field's default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id), title: try container.decode(String.self, forKey: .title),
            note: (try? container.decodeIfPresent(String.self, forKey: .note)) ?? "",
            dueDate: try? container.decodeIfPresent(Date.self, forKey: .dueDate),
            link: try? container.decodeIfPresent(MyTodoLink.self, forKey: .link),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            doneAt: try? container.decodeIfPresent(Date.self, forKey: .doneAt),
            snoozedUntil: try? container.decodeIfPresent(Date.self, forKey: .snoozedUntil))
    }

    /// the id its Inbox entry has
    public var entryID: String { Self.entryIDPrefix + id }

    /// the start of the ids of the Inbox entries of to-dos
    public static let entryIDPrefix = "mine|"
}

/// What a to-do is about: a GitLab merge request or work item, a Jenkins build, or any other page. Shown as the app-wide
/// reference chip, blue `#` or green `!`, and opened in the app.
public struct MyTodoLink: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case mergeRequest
        case workItem
        case build
        case web
    }

    public var url: URL
    public var kind: Kind
    /// the number the chip shows, like `group/project!12`, `!12` or `#7`; `nil` for a page without one
    public var reference: String?

    public init(url: URL, kind: Kind, reference: String?) {
        self.url = url
        self.kind = kind
        self.reference = reference
    }

    /// What a link's words are when a to-do has no title of its own: "Merge request !12".
    public var defaultTitle: String {
        switch kind {
        case .mergeRequest: "Merge request \(shortReference ?? "")"
        case .workItem: "Work item \(shortReference ?? "")"
        case .build: shortReference.map { "Build of \($0)" } ?? "Build"
        case .web: url.host(percentEncoded: false) ?? "Link"
        }
    }

    private var shortReference: String? {
        reference.flatMap { reference in
            reference.lastIndex(where: { $0 == "!" || $0 == "#" }).map { String(reference[$0...]) }
        }
    }

    // MARK: - Reading text

    /// What the words of the quick-add field are made of.
    public struct Parsed: Hashable, Sendable {
        /// the title: the words without the link that became the chip
        public var title: String
        public var link: MyTodoLink?
    }

    /// The places a link is read against: the Jenkins jobs and GitLab instances of the projects, and the primary project,
    /// which a bare `!123` or `#123` means.
    public struct Context: Sendable {
        var router: LinkRouter
        var gitLab: URL?
        var project: String?

        /// - Parameters:
        ///   - projects: the team's projects
        ///   - primary: the project a bare number means
        public init(projects: [Project], primary: Project?) {
            router = LinkRouter(projects: projects)
            gitLab = primary?.team.gitLab
            let path = primary?.team.gitLabProject.trimmingCharacters(in: .whitespaces)
            project = path?.isEmpty == false ? path : nil
        }

        /// no project: only links of any host read, and a bare number reads as nothing
        public init() {
            router = LinkRouter(projects: [])
        }
    }

    /// Reads the words of the quick-add field: a pasted GitLab or Jenkins link becomes the chip and leaves the title; a
    /// bare `!123` or `#123` becomes the chip of the primary project's merge request or work item and stays in the title.
    /// The first one wins.
    ///
    /// - Parameters:
    ///   - text: what was typed or pasted
    ///   - context: the projects the link is read against
    /// - Returns: the title and the link; the title is the link's default when the words were only the link
    public static func parse(_ text: String, context: Context) -> Parsed {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var link: MyTodoLink?
        for (index, word) in words.enumerated() {
            if let found = readURL(word, context: context) {
                link = found
                words.remove(at: index)
                break
            }
            if let found = readNumber(word, context: context) {
                link = found
                break
            }
        }
        let title = words.joined(separator: " ")
        return Parsed(title: title.isEmpty ? (link?.defaultTitle ?? "") : title, link: link)
    }

    /// Reads one field that holds a link and nothing else, as the edit sheet's link field does.
    ///
    /// - Parameters:
    ///   - text: what was typed or pasted
    ///   - context: the projects the link is read against
    /// - Returns: the link; `nil` for text that isn't one
    public static func parseLink(_ text: String, context: Context) -> MyTodoLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return readURL(trimmed, context: context) ?? readNumber(trimmed, context: context)
    }

    private static func readURL(_ word: String, context: Context) -> MyTodoLink? {
        let lower = word.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://"), let url = URL(string: word),
            url.host(percentEncoded: false)?.isEmpty == false
        else {
            return nil
        }
        switch context.router.route(url) {
        case .mergeRequest(let project, let iid):
            return MyTodoLink(url: url, kind: .mergeRequest, reference: "\(project)!\(iid)")
        case .workItem(let project, let iid):
            return MyTodoLink(url: url, kind: .workItem, reference: "\(project)#\(iid)")
        case .jenkinsBuild(_, let job, _):
            return MyTodoLink(url: url, kind: .build, reference: mergeRequestNumber(ofJob: job).map { "!\($0)" })
        case .jenkinsJob, .pipeline, .browser:
            return MyTodoLink(url: url, kind: .web, reference: nil)
        }
    }

    /// `MR-12501` → 12501
    private static func mergeRequestNumber(ofJob job: String) -> Int? {
        let name = job.removingPercentEncoding ?? job
        guard name.hasPrefix("MR-") else {
            return nil
        }
        return Int(name.dropFirst(3))
    }

    private static func readNumber(_ word: String, context: Context) -> MyTodoLink? {
        // "!123," or "(#45)": a number with the punctuation of a sentence around it.
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:()[]"))
        guard let sign = trimmed.first, sign == "!" || sign == "#", let number = Int(trimmed.dropFirst()), number > 0,
            let gitLab = context.gitLab, let project = context.project
        else {
            return nil
        }
        let base = gitLab.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let kind = sign == "!" ? "merge_requests" : "work_items"
        guard let url = URL(string: "\(base)/\(project)/-/\(kind)/\(number)") else {
            return nil
        }
        return MyTodoLink(url: url, kind: sign == "!" ? .mergeRequest : .workItem, reference: "\(project)\(sign)\(number)")
    }
}

/// What the user typed into a to-do's form, ready to keep.
public struct MyTodoDraft: Hashable, Sendable {
    public var title: String
    public var note: String
    public var dueDate: Date?
    public var link: MyTodoLink?

    public init(title: String, note: String = "", dueDate: Date? = nil, link: MyTodoLink? = nil) {
        self.title = title
        self.note = note
        self.dueDate = dueDate
        self.link = link
    }
}

/// The user's to-dos in their own order (Task 7.03): the list `InboxStore` keeps in `Inbox/my-todos.json`. Pure, so the
/// order and the checkboxes are testable.
public struct MyTodoList: Codable, Hashable, Sendable {
    /// in the user's order; new ones go on top
    public private(set) var todos: [MyTodo]

    /// how long a done to-do stays
    public static let doneKeptFor: TimeInterval = 90 * 24 * 3600

    public init(todos: [MyTodo] = []) {
        self.todos = todos
    }

    /// Puts a new to-do on top.
    public mutating func add(_ todo: MyTodo) {
        todos.insert(todo, at: 0)
    }

    /// Changes a to-do's words, date and link.
    ///
    /// - Returns: whether the to-do exists
    @discardableResult
    public mutating func update(_ id: String, with draft: MyTodoDraft) -> Bool {
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            return false
        }
        todos[index].title = draft.title
        todos[index].note = draft.note
        todos[index].dueDate = draft.dueDate
        todos[index].link = draft.link
        return true
    }

    /// Ticks a to-do, or takes the tick away; a done to-do isn't snoozed.
    public mutating func setDone(_ id: String, at date: Date?) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            return
        }
        todos[index].doneAt = date
        todos[index].snoozedUntil = nil
    }

    /// Lets a to-do sleep until a time, or wakes it with `nil`.
    public mutating func setSnooze(_ id: String, until date: Date?) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            return
        }
        todos[index].snoozedUntil = date
    }

    public mutating func remove(_ id: String) {
        todos.removeAll { $0.id == id }
    }

    /// Moves the pending to-dos the list shows, as a drag does; the done and the snoozed ones keep their places.
    ///
    /// - Parameters:
    ///   - visible: the ids of the shown to-dos, in the order shown
    ///   - source: the offsets of the dragged rows in `visible`, as SwiftUI's `onMove` gives them
    ///   - destination: the offset in `visible` the rows are dropped before
    public mutating func move(visible: [String], from source: IndexSet, to destination: Int) {
        let dragged = source.filter { visible.indices.contains($0) }.map { visible[$0] }
        var order = visible.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let position = destination - source.count { $0 < destination }
        order.insert(contentsOf: dragged, at: min(max(position, 0), order.count))
        let shown = Set(visible)
        let slots = todos.indices.filter { shown.contains(todos[$0].id) }
        guard slots.count == order.count else {
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: todos.map { ($0.id, $0) })
        for (slot, id) in zip(slots, order) {
            if let todo = byID[id] {
                todos[slot] = todo
            }
        }
    }

    /// Drops the to-dos that were done long ago.
    public mutating func prune(now: Date) {
        todos.removeAll { $0.doneAt.map { now.timeIntervalSince($0) > Self.doneKeptFor } ?? false }
    }
}
