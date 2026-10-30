import Foundation

// MARK: - Picking lines in a diff

/// A line of a file's diff, by its numbers: the old one for a removed line, the new one for an added line, both for an
/// unchanged one. Within one file's diff no two lines have the same pair, so it names a line in both layouts.
public struct DiffLineID: Hashable, Sendable {
    public var old: Int?
    public var new: Int?

    public init(old: Int?, new: Int?) {
        self.old = old
        self.new = new
    }

    public init(_ line: DiffLine) {
        self.init(old: line.oldNumber, new: line.newNumber)
    }
}

/// The lines of a file's diff picked by clicking their numbers (AI-07): a click picks a line, a shift-click extends the
/// pick to another line of the same file.
public struct DiffSelection: Hashable, Sendable {
    /// the file's path, as the Changes card shows it
    public var path: String
    /// the line clicked first, which a shift-click extends from
    public var anchor: DiffLineID
    /// the line clicked last
    public var head: DiffLineID

    public init(path: String, anchor: DiffLineID, head: DiffLineID) {
        self.path = path
        self.anchor = anchor
        self.head = head
    }

    /// Returns the selection after a click on a line's number: a click picks that line alone, or unpicks it when it was
    /// the only line picked; a shift-click extends from the line clicked first to this one, and in another file starts
    /// anew.
    ///
    /// - Parameters:
    ///   - line: the clicked line
    ///   - path: the clicked line's file
    ///   - extending: whether Shift was down
    ///   - current: the selection before the click
    /// - Returns: the new selection; `nil` for none
    public static func click(
        _ line: DiffLineID, path: String, extending: Bool, in current: DiffSelection?
    ) -> DiffSelection? {
        if let current, current.path == path {
            if extending {
                return DiffSelection(path: path, anchor: current.anchor, head: line)
            }
            if current.anchor == line, current.head == line {
                return nil
            }
        }
        return DiffSelection(path: path, anchor: line, head: line)
    }

    /// Returns the picked lines in the diff's order, from whichever of the two clicked lines comes first to the other,
    /// across hunks; empty when a clicked line is no longer in the diff.
    ///
    /// - Parameter hunks: the file's hunks
    public func lines(in hunks: [DiffHunk]) -> [DiffLine] {
        let all = hunks.flatMap(\.lines)
        guard let first = all.firstIndex(where: { DiffLineID($0) == anchor }),
            let second = all.firstIndex(where: { DiffLineID($0) == head })
        else {
            return []
        }
        return Array(all[min(first, second)...max(first, second)])
    }

    /// Returns the numbers the picked lines span: the new file's where any picked line is in it, else the old file's.
    ///
    /// - Parameter hunks: the file's hunks
    /// - Returns: the span; `nil` when nothing is picked
    public func span(in hunks: [DiffHunk]) -> LineSpan? {
        let picked = lines(in: hunks)
        let new = picked.compactMap(\.newNumber)
        if let first = new.min(), let last = new.max() {
            return LineSpan(first: first, last: last, isOld: false)
        }
        let old = picked.compactMap(\.oldNumber)
        guard let first = old.min(), let last = old.max() else {
            return nil
        }
        return LineSpan(first: first, last: last, isOld: true)
    }
}

/// The numbers a pick of lines spans, in the new file, or in the old one when only removed lines are picked.
public struct LineSpan: Hashable, Sendable {
    public var first: Int
    public var last: Int
    /// whether the numbers are the old file's: only removed lines are picked
    public var isOld: Bool

    public init(first: Int, last: Int, isOld: Bool = false) {
        self.first = first
        self.last = last
        self.isOld = isOld
    }

    /// "Lines 12–30", "Line 12", "Removed Lines 4–6", in Title Style for a button
    public var buttonTitle: String {
        (isOld ? "Removed " : "") + (first == last ? "Line \(first)" : "Lines \(first)–\(last)")
    }

    /// "lines 12–30", "line 12", "removed lines 4–6"
    public var title: String {
        (isOld ? "removed " : "") + (first == last ? "line \(first)" : "lines \(first)–\(last)")
    }
}

// MARK: - The question

/// What a question about a merge request's code is about (AI-07): picked lines of a file, a whole file, or the whole
/// merge request.
public enum CodeScope: Hashable, Sendable {
    case lines(DiffSelection, LineSpan)
    /// a file, by its path
    case file(String)
    case mergeRequest

    /// "lines 12–30 of Sources/App.swift", "Sources/App.swift", "the whole merge request"
    public var title: String {
        switch self {
        case .lines(let selection, let span): "\(span.title) of \(selection.path)"
        case .file(let path): path
        case .mergeRequest: "the whole merge request"
        }
    }

    /// the file the scope is in; `nil` for the whole merge request
    public var path: String? {
        switch self {
        case .lines(let selection, _): selection.path
        case .file(let path): path
        case .mergeRequest: nil
        }
    }
}

/// The inline chat about a merge request's code (AI-07).
public enum CodeChat {
    /// The quick picks above the field: a title and the words they put in it.
    public static let quickPicks: [(title: String, question: String)] = [
        ("Review This", "Review this code: list real problems first (bugs, edge cases, security, error handling), then smaller points. Say where, with the file and line."),
        ("Explain This", "Explain what this code does and why it changed, for a reviewer who doesn't know this part of the code."),
        ("Find Bugs", "Look for bugs only: wrong logic, missed edge cases, races, leaks, wrong error handling. For each: where, why, and how to fix it."),
        ("Suggest Tests", "Suggest the tests this change needs: what each test checks and why it matters. Name the cases, not boilerplate."),
    ]
}

/// The checkout of a merge request's source branch, which Claude may read (AI-07).
public struct CheckoutAccess: Hashable, Sendable {
    /// the checkout's folder, absolute
    public var path: String
    /// the checkout's name, like `develop3`
    public var name: String
    /// the branch checked out; `nil` for a detached HEAD or when unknown
    public var branch: String?
    /// HEAD's commit; `nil` when git didn't say
    public var head: String?

    public init(path: String, name: String, branch: String?, head: String? = nil) {
        self.path = path
        self.name = name
        self.branch = branch
        self.head = head
    }
}

/// What a question about a merge request's code is sent with (AI-07): the merge request, its description, the scope's
/// diff, and the checkout Claude may read. Links would be no use: Claude can't sign in to GitLab, and the app never
/// hands it a token.
public struct CodeQuestionFacts: Hashable, Sendable {
    public var reference: String
    public var title: String
    public var author: MergeRequest.Person
    public var sourceBranch: String?
    public var targetBranch: String?
    /// the merge request's head commit, when GitLab said
    public var headCommit: String?
    /// the description's Markdown, when loaded
    public var description: String?
    public var scope: CodeScope
    /// the changed files, with the diffs loaded for the scope
    public var changes: MergeRequestChanges
    /// the checkout Claude may read; `nil` sends no tools
    public var checkout: CheckoutAccess?

    public init(
        reference: String, title: String, author: MergeRequest.Person, sourceBranch: String? = nil,
        targetBranch: String? = nil, headCommit: String? = nil, description: String? = nil, scope: CodeScope,
        changes: MergeRequestChanges, checkout: CheckoutAccess? = nil
    ) {
        self.reference = reference
        self.title = title
        self.author = author
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.headCommit = headCommit
        self.description = description
        self.scope = scope
        self.changes = changes
        self.checkout = checkout
    }

    /// the longest description sent, in characters
    public static let descriptionCharacters = 4_000
    /// the diff lines sent before and after picked lines
    public static let contextLines = 20
    /// the most diff text sent, in characters: about 20,000 tokens
    public static let diffCharacters = 80_000
    /// the paths listed of the files left out
    public static let listedCutFiles = 100

    /// Returns whether a checkout is on the merge request's source branch, so Claude may read it.
    ///
    /// - Parameters:
    ///   - checkout: the checkout, or `nil`
    ///   - sourceBranch: the merge request's source branch
    /// - Returns: the checkout, when it may be read
    public static func readable(_ checkout: CheckoutAccess?, sourceBranch: String?) -> CheckoutAccess? {
        guard let checkout, checkout.path.hasPrefix("/"), let branch = checkout.branch, branch == sourceBranch else {
            return nil
        }
        return checkout
    }
}

extension ClaudePrompt {
    /// the system prompt of a question about code, without a checkout
    static let codeQuestionInstructions = """
        You answer a developer's question about the code of a GitLab merge request. You get the merge request, its \
        description, and the diff of what the question is about; answer from them. You can't run commands, open \
        links or change anything. Answer in Markdown, concise and concrete: most important first, name the file and \
        line for each point, show code only where it helps. Say plainly when the diff doesn't tell enough to be sure.
        """

    /// the system prompt of a question about code, with a checkout Claude may read
    static let codeQuestionReadingInstructions = """
        You answer a developer's question about the code of a GitLab merge request. You get the merge request, its \
        description, and the diff of what the question is about. You may also read the merge request's branch in a \
        local checkout with Read, Grep and Glob, to look at whole files, callers and tests; the facts say whether the \
        checkout matches the merge request's head. You can't run commands, open links or change anything. Answer in \
        Markdown, concise and concrete: most important first, name the file and line for each point, show code only \
        where it helps. Say plainly when you aren't sure.
        """

    /// Returns the prompt of a question about a merge request's code (AI-07): the merge request, its description, the
    /// scope's diff with line numbers (picked lines marked, with the hunks' lines around them; a whole file; or every
    /// file, cut at ``CodeQuestionFacts/diffCharacters`` with the files left out named), the checkout when Claude may
    /// read it, and the question last.
    ///
    /// - Parameters:
    ///   - facts: the merge request, the scope and its diff
    ///   - question: the user's question
    /// - Returns: the prompt, not redacted yet; with the checkout as its readable folder when there is one
    public static func codeQuestion(_ facts: CodeQuestionFacts, question: String) -> ClaudePrompt {
        func person(_ person: MergeRequest.Person) -> String {
            person.name.isEmpty ? person.username : "\(person.name) (\(person.username))"
        }
        var lines = ["Answer my question about this merge request's code.", ""]
        lines.append("# Merge request")
        lines.append("\(facts.reference) \"\(facts.title)\" by \(person(facts.author))")
        if let source = facts.sourceBranch {
            lines.append("Branches: \(source) into \(facts.targetBranch ?? "its target branch")")
        }
        if let head = facts.headCommit {
            lines.append("Head commit: \(head)")
        }
        let description = facts.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !description.isEmpty {
            lines.append("")
            lines.append("# Description")
            lines.append(head(description, characters: CodeQuestionFacts.descriptionCharacters))
        }

        lines.append("")
        lines.append(contentsOf: diffSection(facts))

        let readable = CodeQuestionFacts.readable(facts.checkout, sourceBranch: facts.sourceBranch)
        if let checkout = readable {
            lines.append("")
            lines.append("# Local checkout")
            lines.append("You may read the merge request's branch at \(checkout.path) with Read, Grep and Glob (read only).")
            let branch = checkout.branch ?? "its branch"
            switch (checkout.head, facts.headCommit) {
            case (let local?, let remote?) where remote.hasPrefix(local) || local.hasPrefix(remote):
                lines.append("Checked out: \(branch) at \(local), the merge request's head.")
            case (let local?, let remote?):
                lines.append(
                    "Checked out: \(branch) at \(local), not the merge request's head \(remote): the files may differ from the diff; the diff is right.")
            case (let local?, nil):
                lines.append("Checked out: \(branch) at \(local); the merge request's head is unknown, so the files may differ from the diff.")
            case (nil, _):
                lines.append("Checked out: \(branch); its commit is unknown, so the files may differ from the diff.")
            }
        }

        lines.append("")
        lines.append("# Question")
        lines.append(question.trimmingCharacters(in: .whitespacesAndNewlines))
        var prompt = ClaudePrompt(
            useCase: .askAboutCode,
            instructions: readable == nil ? codeQuestionInstructions : codeQuestionReadingInstructions,
            text: lines.joined(separator: "\n"))
        prompt.readableFolder = readable?.path
        prompt.question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt
    }

    /// Returns the section with the scope's diff, numbered, which a first question and a follow-up with another scope
    /// both send: picked lines marked with the hunks' lines around them, a whole file, or every file (cut).
    ///
    /// - Parameter facts: the merge request, the scope and its diff
    /// - Returns: the lines of the section, headed "# Diff: …"
    static func diffSection(_ facts: CodeQuestionFacts) -> [String] {
        var lines: [String] = []
        lines.append("# Diff: \(facts.scope.title)")
        lines.append(
            "Each line: its old number, its new number, then \"+\" added, \"-\" removed or \" \" unchanged, then the code.")
        switch facts.scope {
        case .lines(let selection, _):
            lines.append("The lines the question is about are marked with \">\"; the others are the diff around them.")
            if let file = facts.changes.files.first(where: { $0.path == selection.path || $0.newPath == selection.path }) {
                lines.append(contentsOf: pickedLines(of: file, selection: selection))
            } else {
                lines.append("(the file's diff isn't loaded)")
            }
        case .file(let path):
            if let file = facts.changes.files.first(where: { $0.path == path || $0.newPath == path }) {
                lines.append(contentsOf: wholeFile(file, characters: CodeQuestionFacts.diffCharacters))
            } else {
                lines.append("(the file's diff isn't loaded)")
            }
        case .mergeRequest:
            lines.append(contentsOf: everyFile(facts.changes))
        }
        return lines
    }

    /// Returns the diff a follow-up is about, when its scope isn't the one the facts of the first question hold.
    ///
    /// - Parameter facts: the merge request, the follow-up's scope and its diff
    /// - Returns: the text, not redacted yet
    public static func followUpDiff(_ facts: CodeQuestionFacts) -> String {
        diffSection(facts).joined(separator: "\n")
    }

    /// A diff line as sent: the mark, both numbers, the sign, the code.
    private static func diffLine(_ line: DiffLine, width: Int, marked: Bool = false) -> String {
        func number(_ value: Int?) -> String {
            let text = value.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, width - text.count)) + text
        }
        let sign = switch line.kind {
        case .added: "+"
        case .removed: "-"
        case .context: " "
        }
        return "\(marked ? ">" : " ")\(number(line.oldNumber)) \(number(line.newNumber)) \(sign) \(line.text)"
    }

    /// the widest line number of a file's hunks, in digits
    private static func numberWidth(_ hunks: [DiffHunk]) -> Int {
        String(hunks.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 1).count
    }

    /// A file's heading: its path, how it changed, its +/−.
    private static func fileHeading(_ file: MergeRequestChanges.FileChange) -> String {
        var kind = switch file.kind {
        case .added: "added"
        case .deleted: "deleted"
        case .renamed: "renamed from \(file.oldPath)"
        case .modified: "modified"
        case nil: "changed"
        }
        if file.isGenerated {
            kind += ", generated"
        }
        return "## \(file.path) (\(kind), +\(file.additions) -\(file.deletions))"
    }

    /// What a file without lines to send says instead; `nil` when it has hunks.
    private static func noLines(_ file: MergeRequestChanges.FileChange) -> String? {
        switch file.content {
        case .hunks(let hunks) where !hunks.isEmpty: nil
        case .hunks, .empty: "(no line changed)"
        case .binary: "(a binary file)"
        case .notShown: "(too large: GitLab didn't send its diff)"
        case .notLoaded: "(its diff isn't loaded)"
        }
    }

    /// The picked lines of a file, marked, with up to ``CodeQuestionFacts/contextLines`` lines of its diff before and
    /// after them; a hunk header where a hunk starts.
    private static func pickedLines(of file: MergeRequestChanges.FileChange, selection: DiffSelection) -> [String] {
        var lines = [fileHeading(file)]
        let picked = Set(selection.lines(in: file.hunks).map(DiffLineID.init))
        guard !picked.isEmpty else {
            lines.append(noLines(file) ?? "(the picked lines are no longer in the diff)")
            return lines
        }
        let width = numberWidth(file.hunks)
        let all = file.hunks.flatMap { hunk in hunk.lines.enumerated().map { (hunk: hunk, line: $0.element, starts: $0.offset == 0) } }
        let indices = all.indices.filter { picked.contains(DiffLineID(all[$0].line)) }
        guard let first = indices.first, let last = indices.last else {
            return lines
        }
        let from = max(0, first - CodeQuestionFacts.contextLines)
        let to = min(all.count - 1, last + CodeQuestionFacts.contextLines)
        for index in from...to {
            let entry = all[index]
            if entry.starts || index == from {
                lines.append(entry.hunk.section.isEmpty ? entry.hunk.header : "\(entry.hunk.header) \(entry.hunk.section)")
            }
            lines.append(diffLine(entry.line, width: width, marked: picked.contains(DiffLineID(entry.line))))
        }
        return lines
    }

    /// A file's whole diff, cut at a number of characters with the lines left out counted.
    private static func wholeFile(_ file: MergeRequestChanges.FileChange, characters: Int) -> [String] {
        var lines = [fileHeading(file)]
        if let none = noLines(file) {
            lines.append(none)
            return lines
        }
        let width = numberWidth(file.hunks)
        var used = 0
        let total = file.hunks.reduce(0) { $0 + $1.lines.count }
        var sent = 0
        for hunk in file.hunks {
            let header = hunk.section.isEmpty ? hunk.header : "\(hunk.header) \(hunk.section)"
            guard used + header.count <= characters else {
                break
            }
            lines.append(header)
            used += header.count + 1
            for line in hunk.lines {
                let text = diffLine(line, width: width)
                guard used + text.count <= characters else {
                    lines.append("(cut: \(total - sent) more lines of this file)")
                    return lines
                }
                lines.append(text)
                used += text.count + 1
                sent += 1
            }
        }
        if sent < total {
            lines.append("(cut: \(total - sent) more lines of this file)")
        }
        return lines
    }

    /// Every file's diff in GitLab's order, generated files by name only, until ``CodeQuestionFacts/diffCharacters``;
    /// then the files left out, named with their +/−.
    private static func everyFile(_ changes: MergeRequestChanges) -> [String] {
        var lines: [String] = []
        var used = 0
        var cut: [MergeRequestChanges.FileChange] = []
        for file in changes.files {
            guard cut.isEmpty else {
                cut.append(file)
                continue
            }
            if file.isGenerated {
                let text = [fileHeading(file), "(generated: its diff is left out)"]
                lines.append(contentsOf: text)
                used += text.reduce(0) { $0 + $1.count + 1 }
                continue
            }
            let part = wholeFile(file, characters: .max)
            let size = part.reduce(0) { $0 + $1.count + 1 }
            if used + size > CodeQuestionFacts.diffCharacters {
                // A file too big alone still sends its start, when it is the first.
                if lines.isEmpty {
                    let start = wholeFile(file, characters: CodeQuestionFacts.diffCharacters)
                    lines.append(contentsOf: start)
                    used += start.reduce(0) { $0 + $1.count + 1 }
                    continue
                }
                cut.append(file)
                continue
            }
            lines.append(contentsOf: part)
            used += size
        }
        if changes.files.isEmpty {
            lines.append(changes.isComplete ? "(no file changed)" : "(the changed files aren't loaded)")
        }
        if !cut.isEmpty {
            let additions = cut.reduce(0) { $0 + $1.additions }
            let deletions = cut.reduce(0) { $0 + $1.deletions }
            lines.append("")
            lines.append("# Cut for length: \(cut.count) more \(cut.count == 1 ? "file" : "files") (+\(additions) -\(deletions)), not shown")
            for file in cut.prefix(CodeQuestionFacts.listedCutFiles) {
                lines.append("- \(file.path) (+\(file.additions) -\(file.deletions))")
            }
            if cut.count > CodeQuestionFacts.listedCutFiles {
                lines.append("- and \(cut.count - CodeQuestionFacts.listedCutFiles) more")
            }
        }
        if !changes.isComplete, !changes.files.isEmpty {
            lines.append("(GitLab's list of files may be incomplete)")
        }
        return lines
    }
}

// MARK: - Gathering

/// What GitLab tells of a merge request beyond the list: its target branch, its head commit and its description.
struct CodeQuestionMeta: Hashable, Sendable {
    var targetBranch: String?
    var headCommit: String?
    var description: String?
}

extension GitLabOperation where Value == CodeQuestionMeta {
    /// The target branch, the head commit and the description of a merge request (GitLab's GraphQL reference:
    /// `MergeRequest.targetBranch`, `diffHeadSha`, `description`).
    ///
    /// - Parameter source: the merge request
    /// - Returns: the operation, or `nil` for a reference without a path or an iid
    static func codeQuestionMeta(of source: DescriptionSource) -> GitLabOperation? {
        guard let (path, iid) = source.pathAndIID else {
            return nil
        }
        return GitLabOperation(
            name: "MergeRequestCodeFacts",
            query: """
                query MergeRequestCodeFacts($path: ID!, $iid: String!) {
                  project(fullPath: $path) { mergeRequest(iid: $iid) { targetBranch diffHeadSha description } }
                }
                """,
            variables: .object([("path", .string(path)), ("iid", .string(iid))]),
            decode: { body in
                guard let found = try GraphQLAnswer<MetaShape>.value(of: body).project?.mergeRequest else {
                    throw DecodingError.valueNotFound(
                        CodeQuestionMeta.self, .init(codingPath: [], debugDescription: "no merge request"))
                }
                return CodeQuestionMeta(
                    targetBranch: found.targetBranch, headCommit: found.diffHeadSha, description: found.description)
            })
    }
}

private struct MetaShape: Decodable {
    var project: Project?

    struct Project: Decodable {
        var mergeRequest: MergeRequest?
    }

    struct MergeRequest: Decodable {
        var targetBranch: String?
        var diffHeadSha: String?
        var description: String?
    }
}

extension CodeQuestionFacts {
    /// the pages of diffs read at most for one question, of ``pageSize`` files
    static let maxPages = 40
    static let pageSize = 50

    /// Fills in the diffs a scope needs that the Changes card hasn't loaded: the scope's file, or every file until the
    /// diff text would pass ``diffCharacters``. Pages are read in order; a page that fails ends the reading.
    ///
    /// - Parameters:
    ///   - changes: the changes as loaded
    ///   - scope: the question's scope
    ///   - client: the GitLab client
    ///   - source: the merge request
    /// - Returns: the changes with the diffs read
    static func filling(
        _ changes: MergeRequestChanges, for scope: CodeScope, client: GitLabClient, source: DescriptionSource
    ) async -> MergeRequestChanges {
        var changes = changes
        func needsMore() -> Bool {
            if let path = scope.path {
                return changes.files.first { $0.path == path || $0.newPath == path }?.content == .notLoaded
                    || !changes.files.contains { $0.path == path || $0.newPath == path }
            }
            // The text already loaded in order, until the first file still missing.
            var size = 0
            for file in changes.files where !file.isGenerated {
                guard file.content != .notLoaded else {
                    return size < diffCharacters
                }
                size += file.hunks.reduce(0) { $0 + $1.lines.reduce(0) { $0 + $1.text.count + 14 } }
                if size >= diffCharacters {
                    return false
                }
            }
            return !changes.isComplete
        }
        var page = 1
        while needsMore(), page <= maxPages {
            guard let diffs = try? await client.diffsPage(of: source, page: page, perPage: pageSize) else {
                break
            }
            changes.merge(diffs.files)
            guard let next = diffs.nextPage else {
                changes.settle()
                break
            }
            page = next
        }
        return changes
    }
}
