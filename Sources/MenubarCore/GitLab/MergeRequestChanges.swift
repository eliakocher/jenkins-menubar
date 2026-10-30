import Foundation
import Observation

/// The code changes of a merge request, file by file (MR-11). Read only.
///
/// The files come from GitLab's list of changed paths first, with their +/− but without their diffs; each file's diff
/// comes later, with its page of GitLab's diffs (``ChangesPaging``), matched to the file by its path.
public struct MergeRequestChanges: Hashable, Sendable {
    /// the changed files, in GitLab's order
    public var files: [FileChange]
    /// whether ``files`` names every changed file: GitLab's list came, or the last page of diffs did
    public var isComplete: Bool
    /// whether the merge request has too many files to load their diffs here (over ``ChangesPaging/listOnlyAbove``)
    public var isListOnly: Bool

    public init(files: [FileChange], isComplete: Bool = true, isListOnly: Bool = false) {
        self.files = files
        self.isComplete = isComplete
        self.isListOnly = isListOnly
    }

    /// all added lines
    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    /// all removed lines
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    /// One changed file.
    public struct FileChange: Hashable, Sendable, Identifiable {
        public var oldPath: String
        public var newPath: String
        /// how the file changed; `nil` while only GitLab's list of paths names the file, which doesn't say
        public var kind: Kind?
        /// whether GitLab marks the file as generated, or its name says so (``GeneratedFiles``)
        public var isGenerated: Bool
        public var content: Content
        /// the added lines: counted in the hunks, or as GitLab's list says while the diff isn't here
        public var additions: Int
        /// the removed lines, counted like ``additions``
        public var deletions: Int

        /// - Parameters:
        ///   - additions: the added lines; `nil` counts them in the hunks
        ///   - deletions: the removed lines; `nil` counts them in the hunks
        public init(
            oldPath: String, newPath: String, kind: Kind?, isGenerated: Bool = false, content: Content,
            additions: Int? = nil, deletions: Int? = nil
        ) {
            self.oldPath = oldPath
            self.newPath = newPath
            self.kind = kind
            self.isGenerated = isGenerated
            self.content = content
            let hunks: [DiffHunk] = if case .hunks(let hunks) = content { hunks } else { [] }
            self.additions = additions ?? hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count }
            self.deletions = deletions ?? hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count }
        }

        /// GitLab's new path, which a deleted file keeps as its old one: the key that matches a diff to the list
        public var id: String { newPath }

        /// the path the file has now; the old one for a deleted file
        public var path: String { kind == .deleted ? oldPath : newPath }

        /// the hunks, empty when the diff didn't come
        public var hunks: [DiffHunk] {
            if case .hunks(let hunks) = content { hunks } else { [] }
        }

        /// Whether the detail shows the file folded until a click: generated files and diffs over ``bigDiff`` lines.
        public var foldsByDefault: Bool {
            let lines = content == .notLoaded ? additions + deletions : hunks.reduce(0) { $0 + $1.lines.count }
            return isGenerated || lines > Self.bigDiff
        }

        /// the diff lines above which a file starts folded
        public static let bigDiff = 500

        /// How the file changed.
        public enum Kind: Hashable, Sendable {
            case added
            case deleted
            case renamed
            case modified
        }

        /// What the detail can show of the file's diff.
        public enum Content: Hashable, Sendable {
            case hunks([DiffHunk])
            /// a binary file: no lines to show
            case binary
            /// GitLab left the diff out: too large to send (`too_large`), collapsed and sent on request only
            /// (`collapsed`), or past the files its diffs have; the detail leaves it to GitLab's page
            case notShown
            /// no line changed: a mode change, or an empty file added or removed
            case empty
            /// the diff's page hasn't come yet, or its text was dropped to save memory
            case notLoaded
        }
    }
}

extension MergeRequestChanges {
    /// Puts a page of diffs on the listed files, matched by path, so GitLab's order of the pages needn't follow the
    /// list's: a diff goes to the file whose path is its new or its old path. A file the list misses is added at the
    /// end. A diff without lines keeps the list's +/−.
    ///
    /// - Parameter page: the files of one page of GitLab's diffs
    public mutating func merge(_ page: [FileChange]) {
        var index: [String: Int] = [:]
        for (offset, file) in files.enumerated() where index[file.newPath] == nil {
            index[file.newPath] = offset
        }
        for var diff in page {
            guard let offset = index[diff.newPath] ?? index[diff.oldPath] else {
                index[diff.newPath] = files.count
                files.append(diff)
                continue
            }
            if diff.hunks.isEmpty {
                diff.additions = files[offset].additions
                diff.deletions = files[offset].deletions
            }
            files[offset] = diff
        }
    }

    /// Marks the files no page brought as left out, once every page came: GitLab's diffs stop at its own limits, which
    /// its list of paths doesn't have.
    mutating func settle() {
        isComplete = true
        for offset in files.indices where files[offset].content == .notLoaded {
            files[offset].content = .notShown
        }
    }

    /// Drops the diff text, which the pages bring again, and keeps the list.
    mutating func dropDiffs() {
        for offset in files.indices {
            switch files[offset].content {
            case .hunks, .binary, .empty: files[offset].content = .notLoaded
            case .notShown, .notLoaded: break
            }
        }
    }
}

/// Which pages of GitLab's diffs to ask for (MR-11): only on demand, each page once.
///
/// A file's page is where its place in the list falls, as GitLab's diffs are expected in the order of its list of
/// paths; when that page came without the file, the first page not asked yet follows, so another order costs pages,
/// not diffs.
public struct ChangesPaging: Hashable, Sendable {
    /// the files of a page: few, so a scroll asks for little
    public static let pageSize = 25
    /// above this many files the detail shows the list only, and GitLab's page for the diffs
    public static let listOnlyAbove = 3000

    public private(set) var loaded: Set<Int> = []
    public private(set) var inFlight: Set<Int> = []
    /// the last page, once GitLab said so (`X-Total-Pages`, or an answer without `X-Next-Page`)
    public private(set) var lastPage: Int?

    public init() {}

    /// whether every page came
    public var isDone: Bool {
        guard let lastPage else {
            return false
        }
        return lastPage < 1 || (1...lastPage).allSatisfy(loaded.contains)
    }

    /// the first page neither loaded nor on its way; `nil` past the last page
    public var nextPage: Int? {
        var page = 1
        while loaded.contains(page) || inFlight.contains(page) {
            page += 1
        }
        return lastPage.map { page <= $0 } ?? true ? page : nil
    }

    /// Returns the page to ask for so a file's diff comes; `nil` while that page is on its way, or when nothing is
    /// left to ask.
    ///
    /// - Parameter index: the file's place in the list, from 0
    public func page(forFileAt index: Int) -> Int? {
        let guess = index / Self.pageSize + 1
        if inFlight.contains(guess) {
            return nil
        }
        if !loaded.contains(guess), lastPage.map({ guess <= $0 }) ?? true {
            return guess
        }
        return nextPage
    }

    /// Notes a page asked for.
    public mutating func start(_ page: Int) {
        inFlight.insert(page)
    }

    /// Notes a page that came.
    ///
    /// - Parameters:
    ///   - page: the page
    ///   - nextPage: GitLab's `X-Next-Page`; `nil` on the last page
    ///   - totalPages: GitLab's `X-Total-Pages`, when it sent one
    ///   - isEmpty: whether the page had no file, as one past the last
    public mutating func finish(_ page: Int, nextPage: Int?, totalPages: Int? = nil, isEmpty: Bool = false) {
        inFlight.remove(page)
        loaded.insert(page)
        if let totalPages {
            lastPage = totalPages
        }
        if nextPage == nil {
            let last = isEmpty ? page - 1 : page
            lastPage = min(lastPage ?? last, last)
        }
    }

    /// Notes a page that failed or was cancelled, so it can be asked again.
    public mutating func fail(_ page: Int) {
        inFlight.remove(page)
    }
}

/// The rows of the Changes card (MR-11): the files in GitLab's order, under a header per folder when there are many,
/// and only those whose path has the filter's text.
public enum ChangesOutline {
    /// up to this many files they show flat, each with its full path; more are grouped by folder
    public static let flatUpTo = 5

    /// Whether the files show under a header per folder.
    public static func isGrouped(_ files: [MergeRequestChanges.FileChange]) -> Bool {
        files.count > flatUpTo
    }

    /// Whether the folders start folded: more than one folder, whatever the file count; a single folder (and a flat
    /// list) starts open.
    public static func startsFolded(_ files: [MergeRequestChanges.FileChange]) -> Bool {
        isGrouped(files) && folderPaths(of: files).count > 1
    }

    /// The folders of the files, each once, in the order their first file comes.
    public static func folderPaths(of files: [MergeRequestChanges.FileChange]) -> [String] {
        var seen: Set<String> = []
        var order: [String] = []
        for file in files {
            let folder = Self.folder(of: file.path)
            if seen.insert(folder).inserted {
                order.append(folder)
            }
        }
        return order
    }

    /// The folders' common start, whole path components with the trailing slash, such as "services/src/"; empty without
    /// one, and for fewer than two folders (a lone folder is its own header).
    public static func commonPrefix(of folders: [String]) -> String {
        guard folders.count > 1 else {
            return ""
        }
        let split = folders.map { $0.split(separator: "/", omittingEmptySubsequences: true) }
        var shared = split[0]
        for components in split.dropFirst() {
            shared = Array(zip(shared, components).prefix { $0 == $1 }.map(\.0))
            if shared.isEmpty {
                return ""
            }
        }
        return shared.joined(separator: "/") + "/"
    }

    /// The ways a folder path can show, longest first: the whole path, then "…/" with fewer and fewer of its last
    /// components. The view takes the first that fits, so a long path is cut at a slash, from the left.
    public static func pathVariants(of path: String) -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else {
            return [path]
        }
        return [path]
            + (1..<components.count).reversed().map { "…/" + components.suffix($0).joined(separator: "/") + "/" }
    }

    /// A row: a folder's header, or a file.
    public enum Row: Hashable, Sendable, Identifiable {
        case folder(Folder)
        /// a file, by its place in the list
        case file(index: Int, id: String)

        public var id: String {
            switch self {
            case .folder(let folder): "folder:\(folder.path)"
            case .file(_, let id): id
            }
        }
    }

    /// A folder's header: its path, its files and their +/−.
    public struct Folder: Hashable, Sendable {
        /// "Sources/Export/"; empty for the files at the top
        public var path: String
        public var fileCount: Int
        public var additions: Int
        public var deletions: Int
        public var isFolded: Bool

        public init(path: String, fileCount: Int, additions: Int, deletions: Int, isFolded: Bool) {
            self.path = path
            self.fileCount = fileCount
            self.additions = additions
            self.deletions = deletions
            self.isFolded = isFolded
        }
    }

    /// Returns the rows.
    ///
    /// - Parameters:
    ///   - files: the files, in GitLab's order
    ///   - filter: the text a path must have, any case; empty for every file. A filter unfolds every folder.
    ///   - isFolded: whether a folder is folded, by its path; asked only when grouped
    public static func rows(
        of files: [MergeRequestChanges.FileChange], filter: String = "", isFolded: (String) -> Bool = { _ in false }
    ) -> [Row] {
        let filter = filter.trimmingCharacters(in: .whitespaces)
        let shown = files.indices.filter { filter.isEmpty || files[$0].path.localizedCaseInsensitiveContains(filter) }
        guard isGrouped(files) else {
            return shown.map { .file(index: $0, id: files[$0].id) }
        }
        // Folders in the order their first file comes, which is GitLab's (git's) order of the paths.
        var order: [String] = []
        var members: [String: [Int]] = [:]
        for index in shown {
            let folder = Self.folder(of: files[index].path)
            if members[folder] == nil {
                order.append(folder)
            }
            members[folder, default: []].append(index)
        }
        var rows: [Row] = []
        for path in order {
            let indices = members[path] ?? []
            let folded = filter.isEmpty && isFolded(path)
            rows.append(
                .folder(
                    Folder(
                        path: path, fileCount: indices.count, additions: indices.reduce(0) { $0 + files[$1].additions },
                        deletions: indices.reduce(0) { $0 + files[$1].deletions }, isFolded: folded)))
            if !folded {
                rows += indices.map { .file(index: $0, id: files[$0].id) }
            }
        }
        return rows
    }

    /// "Sources/Export/" of "Sources/Export/ExportJob.swift"; empty without a folder
    public static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else {
            return ""
        }
        return String(path[...slash])
    }
}

/// The five small blocks beside a "+408 −16" (as GitLab shows them): how many are filled grows with the size of the
/// change, and the filled ones split by the share of additions and deletions.
public enum DiffStatBlocks {
    public enum Block: Hashable, Sendable {
        case added
        case removed
        case none
    }

    /// Returns the five blocks, additions first, then deletions, then the empty ones.
    ///
    /// The filled count is `ceil(log10(total + 1) × 2)`, at least 1 and at most 5: 1 line fills one block, 10 lines
    /// three, 100 or more all five. Each side that changed keeps at least one filled block once two are filled.
    public static func blocks(additions: Int, deletions: Int) -> [Block] {
        let additions = max(additions, 0)
        let deletions = max(deletions, 0)
        let total = additions + deletions
        guard total > 0 else {
            return Array(repeating: .none, count: 5)
        }
        let filled = min(5, max(1, Int((log10(Double(total) + 1) * 2).rounded(.up))))
        let green: Int
        if deletions == 0 {
            green = filled
        } else if additions == 0 {
            green = 0
        } else if filled == 1 {
            green = additions >= deletions ? 1 : 0
        } else {
            green = min(max(Int((Double(filled) * Double(additions) / Double(total)).rounded()), 1), filled - 1)
        }
        return (0..<5).map { index in
            index < green ? .added : index < filled ? .removed : .none
        }
    }
}

// MARK: - Unified diffs

/// A hunk of a unified diff: where it starts on each side and its lines, with their numbers.
public struct DiffHunk: Hashable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// the text after the second `@@`, like the enclosing function's line; empty without one
    public var section: String
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String = "", lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }

    /// "@@ -10,6 +10,8 @@", as diffs show it
    public var header: String {
        "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    }
}

/// A line of a hunk.
public struct DiffLine: Hashable, Sendable {
    public var kind: Kind
    /// the line without its `+`, `-` or space
    public var text: String
    /// the line's number in the old file; `nil` for an added line
    public var oldNumber: Int?
    /// the line's number in the new file; `nil` for a removed line
    public var newNumber: Int?
    /// whether the file ends after this line without a newline (`\ No newline at end of file`)
    public var noNewlineAtEnd: Bool

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?, noNewlineAtEnd: Bool = false) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.noNewlineAtEnd = noNewlineAtEnd
    }

    public enum Kind: Hashable, Sendable {
        case context
        case added
        case removed
    }
}

/// Reads unified diffs, as GitLab and git write them.
public enum UnifiedDiff {
    /// Returns what a file's diff text shows.
    ///
    /// The headers before the first hunk (`diff --git`, `index`, `---`, `+++`) are skipped. A line of `\ No newline at
    /// end of file` marks the line before it. An empty line inside a hunk is an empty context line, which some tools
    /// write without its space. "Binary files … differ" and a `GIT binary patch` are binary.
    ///
    /// - Parameter text: the diff of one file
    /// - Returns: the hunks; `.binary` for a binary file; `.empty` without a hunk
    public static func parse(_ text: String) -> MergeRequestChanges.FileChange.Content {
        var hunks: [DiffHunk] = []
        var oldLine = 0
        var newLine = 0
        // The lines the hunk's header still promises on each side: past them, nothing belongs to the hunk.
        var oldLeft = 0
        var newLeft = 0
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        for raw in lines {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if line.hasPrefix("@@") {
                guard let hunk = header(String(line)) else {
                    continue
                }
                hunks.append(hunk)
                oldLine = hunk.oldStart
                newLine = hunk.newStart
                oldLeft = hunk.oldCount
                newLeft = hunk.newCount
                continue
            }
            guard !hunks.isEmpty else {
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    return .binary
                }
                continue
            }
            let index = hunks.count - 1
            if oldLeft <= 0, newLeft <= 0, line.first != "\\" {
                continue
            }
            switch line.first {
            case "+":
                hunks[index].lines.append(DiffLine(kind: .added, text: String(line.dropFirst()), oldNumber: nil, newNumber: newLine))
                newLine += 1
                newLeft -= 1
            case "-":
                hunks[index].lines.append(DiffLine(kind: .removed, text: String(line.dropFirst()), oldNumber: oldLine, newNumber: nil))
                oldLine += 1
                oldLeft -= 1
            case "\\":
                if !hunks[index].lines.isEmpty {
                    hunks[index].lines[hunks[index].lines.count - 1].noNewlineAtEnd = true
                }
            case " ", nil:
                hunks[index].lines.append(
                    DiffLine(kind: .context, text: String(line.dropFirst()), oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
                oldLeft -= 1
                newLeft -= 1
            default:
                // Another file's headers after a hunk ("diff --git", "index …"): no line of this hunk.
                continue
            }
        }
        return hunks.isEmpty ? .empty : .hunks(hunks)
    }

    /// Returns the hunk a header starts: `@@ -10,6 +10,8 @@ func run()`; a count left out is 1.
    static func header(_ line: String) -> DiffHunk? {
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "@@", parts[3] == "@@", parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
            let old = range(parts[1].dropFirst()), let new = range(parts[2].dropFirst())
        else {
            return nil
        }
        return DiffHunk(
            oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count,
            section: parts.count > 4 ? String(parts[4]) : "", lines: [])
    }

    private static func range(_ text: Substring) -> (start: Int, count: Int)? {
        let numbers = text.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(numbers[0]) else {
            return nil
        }
        guard numbers.count == 2 else {
            return numbers.count == 1 ? (start, 1) : nil
        }
        return Int(numbers[1]).map { (start, $0) }
    }
}

/// The files no one reads in a review: lockfiles, minified and generated files, source maps.
public enum GeneratedFiles {
    private static let names: Set<String> = [
        "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "Package.resolved",
        "Podfile.lock", "Cartfile.resolved", "Gemfile.lock", "Cargo.lock", "composer.lock", "poetry.lock", "Pipfile.lock",
        "uv.lock", "go.sum", "gradle.lockfile", "flake.lock", "mix.lock", "pubspec.lock",
    ]

    /// Returns whether a path names a generated file: a known lockfile, `*.min.*`, `*.map`, or a name with
    /// `.generated.` or `.g.` in it.
    ///
    /// - Parameter path: the file's path in the repository
    public static func isGenerated(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if names.contains(name) {
            return true
        }
        let lower = name.lowercased()
        return lower.contains(".min.") || lower.hasSuffix(".map") || lower.contains(".generated.") || lower.contains(".g.")
    }
}

// MARK: - The requests

/// A page of GitLab's diffs: its files, and where the pages go on.
public struct MergeRequestDiffsPage: Hashable, Sendable {
    public var files: [MergeRequestChanges.FileChange]
    /// GitLab's `X-Next-Page`; `nil` on the last page
    public var nextPage: Int?
    /// GitLab's `X-Total-Pages`, which it can leave out
    public var totalPages: Int?

    public init(files: [MergeRequestChanges.FileChange], nextPage: Int? = nil, totalPages: Int? = nil) {
        self.files = files
        self.nextPage = nextPage
        self.totalPages = totalPages
    }
}

extension GitLabClient {
    /// Asks GitLab for one page of a merge request's diffs: `GET /projects/:path/merge_requests/:iid/diffs` (GitLab's
    /// REST reference; `collapsed` and `too_large` since GitLab 18.4, `generated_file` since 16.9). The diffs are read
    /// here, off the main actor.
    ///
    /// - Parameters:
    ///   - source: the merge request
    ///   - page: the page, from 1
    ///   - perPage: the files of a page
    /// - Returns: the page
    /// - Throws: ``GitLabError`` when GitLab didn't answer or didn't take the request
    public func diffsPage(
        of source: DescriptionSource, page: Int, perPage: Int = ChangesPaging.pageSize
    ) async throws -> MergeRequestDiffsPage {
        guard let (path, iid) = source.pathAndIID,
            var components = URLComponents(url: restBase, resolvingAgainstBaseURL: false)
        else {
            throw GitLabError(.httpStatus(.gitLab, status: 404))
        }
        // The project's path is one segment of the URL, its slashes encoded.
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let project = path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
        components.percentEncodedPath += "/projects/\(project)/merge_requests/\(iid)/diffs"
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "per_page", value: String(perPage)),
        ]
        guard let url = components.url else {
            throw GitLabError(.httpStatus(.gitLab, status: 404))
        }
        let response: HTTPResponse
        do {
            response = try await transport.send(
                HTTPRequest(
                    method: "GET", url: url, headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"],
                    timeout: timeout,
                    // Marks the request as GitLab's for the logs, which tell the servers apart by it.
                    graphQL: GraphQLOperation(name: "MergeRequestDiffs", variables: #"{"page":\#(page)}"#)))
        } catch is TransportError {
            throw GitLabError(.unreachable(.gitLab))
        }
        guard response.status == 200, let diffs = try? JSONDecoder().decode([DiffShape].self, from: response.body) else {
            throw GitLabError(.httpStatus(.gitLab, status: response.status))
        }
        let next = response.header("X-Next-Page").flatMap { Int($0) }.flatMap { $0 > page ? $0 : nil }
        let total = response.header("X-Total-Pages").flatMap { Int($0) }
        return MergeRequestDiffsPage(files: diffs.map(\.fileChange), nextPage: next, totalPages: total)
    }
}

extension GitLabOperation where Value == MergeRequestChanges {
    /// Every changed path of a merge request with its +/−, in one request without the diffs (GitLab's GraphQL
    /// reference: `MergeRequest.diffStats`, `DiffStats { path additions deletions }`). The list doesn't say how a file
    /// changed, nor a rename's old path: those come with the file's page of diffs.
    ///
    /// - Parameter source: the merge request
    /// - Returns: the operation, or `nil` for a reference without a path or an iid. An answer without the merge request
    ///   is a failure.
    static func changedFiles(of source: DescriptionSource) -> GitLabOperation? {
        guard let (path, iid) = source.pathAndIID else {
            return nil
        }
        return GitLabOperation(
            name: "MergeRequestDiffStats",
            query: """
                query MergeRequestDiffStats($path: ID!, $iid: String!) {
                  project(fullPath: $path) { mergeRequest(iid: $iid) { diffStats { path additions deletions } } }
                }
                """,
            variables: .object([("path", .string(path)), ("iid", .string(iid))]),
            decode: { body in
                guard let stats = try GraphQLAnswer<DiffStatsShape>.value(of: body).project?.mergeRequest?.diffStats else {
                    throw DecodingError.valueNotFound(
                        MergeRequestChanges.self, .init(codingPath: [], debugDescription: "no merge request"))
                }
                let files = stats.map { stat in
                    MergeRequestChanges.FileChange(
                        oldPath: stat.path, newPath: stat.path, kind: nil, isGenerated: GeneratedFiles.isGenerated(stat.path),
                        content: .notLoaded, additions: stat.additions, deletions: stat.deletions)
                }
                return MergeRequestChanges(files: files, isListOnly: files.count > ChangesPaging.listOnlyAbove)
            })
    }
}

/// The shape of GitLab's list of changed paths.
struct DiffStatsShape: Decodable {
    var project: Project?

    struct Project: Decodable {
        var mergeRequest: MergeRequest?
    }

    struct MergeRequest: Decodable {
        var diffStats: [Stat]?
    }

    struct Stat: Decodable {
        var path: String
        var additions: Int
        var deletions: Int
    }
}

/// A file of GitLab's diffs answer.
struct DiffShape: Decodable {
    var oldPath: String
    var newPath: String
    var diff: String?
    var newFile: Bool?
    var renamedFile: Bool?
    var deletedFile: Bool?
    var generatedFile: Bool?
    var collapsed: Bool?
    var tooLarge: Bool?

    private enum CodingKeys: String, CodingKey {
        case oldPath = "old_path"
        case newPath = "new_path"
        case diff
        case newFile = "new_file"
        case renamedFile = "renamed_file"
        case deletedFile = "deleted_file"
        case generatedFile = "generated_file"
        case collapsed
        case tooLarge = "too_large"
    }

    var fileChange: MergeRequestChanges.FileChange {
        let kind: MergeRequestChanges.FileChange.Kind =
            newFile == true ? .added : deletedFile == true ? .deleted : renamedFile == true ? .renamed : .modified
        let content: MergeRequestChanges.FileChange.Content
        if collapsed == true || tooLarge == true {
            content = .notShown
        } else {
            content = UnifiedDiff.parse(diff ?? "")
        }
        let path = kind == .deleted ? oldPath : newPath
        return MergeRequestChanges.FileChange(
            oldPath: oldPath, newPath: newPath, kind: kind,
            isGenerated: generatedFile == true || GeneratedFiles.isGenerated(path), content: content)
    }
}

// MARK: - The store

/// What is known of a merge request's changes: the files so far, whether they are for the merge request's last update,
/// whether the list failed, and whether a page of diffs is on its way.
public struct MergeRequestChangesState: Hashable, Sendable {
    /// as last loaded, maybe for an older update of the merge request; `nil` before an answer
    public var changes: MergeRequestChanges?
    /// whether ``changes`` belongs to the merge request's last update
    public var isCurrent: Bool
    /// whether the last request for the files failed
    public var failed: Bool
    /// whether a page of diffs is on its way
    public var isLoadingDiffs: Bool

    public init(changes: MergeRequestChanges?, isCurrent: Bool, failed: Bool = false, isLoadingDiffs: Bool = false) {
        self.changes = changes
        self.isCurrent = isCurrent
        self.failed = failed
        self.isLoadingDiffs = isLoadingDiffs
    }

    /// asked, with no answer yet
    public static let loading = MergeRequestChangesState(changes: nil, isCurrent: false)

    /// Returns the answer for the merge request's last update.
    public static func loaded(_ changes: MergeRequestChanges) -> MergeRequestChangesState {
        MergeRequestChangesState(changes: changes, isCurrent: true)
    }
}

/// The changes of the merge requests the user selected (MR-11), loaded when the Changes card shows and kept small.
///
/// - Selecting a merge request asks nothing. Opening its Changes card asks for GitLab's list of changed paths, then the
///   first page of diffs; every other page only when a file of it shows or is unfolded (``loadDiff(of:fileAt:)``).
///   Without GitLab's list (an older GitLab) the files come with the pages.
/// - Selecting another merge request cancels the requests on their way and drops the diffs of the others, which their
///   pages bring again; the lists of the last ``kept`` merge requests stay.
/// - The list is kept for the merge request's last update: every push updates the merge request, so opening it again
///   asks nothing until the list of merge requests brings a newer `updatedAt`.
@Observable @MainActor
public final class MergeRequestChangesStore {
    private struct Entry {
        var changes: MergeRequestChanges?
        var changesUpdatedAt: Date?
        var paging = ChangesPaging()
        var isListing = false
        var failed = false
        /// counts the resets, so an answer for pages since dropped is ignored
        var generation = 0
    }

    /// the merge requests whose list of files stays in memory
    public static let kept = 5

    private var entries: [String: Entry] = [:]
    /// the selected merge requests, by reference, the newest first; only the first keeps its diffs
    @ObservationIgnored private var recent: [String] = []
    /// the requests on their way, by merge request, to cancel when another is selected
    @ObservationIgnored private var running: [String: [UUID: @MainActor () -> Void]] = [:]
    @ObservationIgnored private let services: GitLabServices

    /// - Parameter services: the transport, the token and the team values; the logs record the requests
    public init(services: GitLabServices) {
        self.services = services
    }

    /// Returns what is known of a merge request's changes.
    ///
    /// - Parameter mergeRequest: the merge request
    public func state(of mergeRequest: MergeRequest) -> MergeRequestChangesState {
        guard let entry = entries[mergeRequest.reference] else {
            return .loading
        }
        let isCurrent = entry.changesUpdatedAt.map { $0 >= mergeRequest.updatedAt } ?? false
        return MergeRequestChangesState(
            changes: entry.changes, isCurrent: entry.changes != nil && isCurrent, failed: entry.failed && !entry.isListing,
            isLoadingDiffs: !entry.paging.inFlight.isEmpty)
    }

    /// Selects a merge request, asking nothing: cancels the requests of the others, drops their diffs, and forgets the
    /// merge requests past the last ``kept``.
    ///
    /// - Parameter mergeRequest: the selected merge request
    public func select(_ mergeRequest: MergeRequest) {
        let key = mergeRequest.reference
        guard recent.first != key else {
            return
        }
        for (other, cancels) in running where other != key {
            cancels.values.forEach { $0() }
        }
        running = running.filter { $0.key == key }
        for other in entries.keys where other != key {
            entries[other]?.changes?.dropDiffs()
            entries[other]?.paging = ChangesPaging()
            entries[other]?.isListing = false
            entries[other]?.generation += 1
        }
        recent.removeAll { $0 == key }
        recent.insert(key, at: 0)
        for forgotten in recent.dropFirst(Self.kept) {
            entries[forgotten] = nil
        }
        recent = Array(recent.prefix(Self.kept))
    }

    /// Loads the list of a merge request's changed files when its Changes card shows, then their first page of diffs;
    /// unless the list is loading, or was loaded for the merge request's last update. Without a GitLab token or the
    /// team values it asks nothing and fails quietly. Over ``ChangesPaging/listOnlyAbove`` files, no diff is asked.
    ///
    /// - Parameters:
    ///   - mergeRequest: the selected merge request
    ///   - force: lists the files again although the list belongs to the merge request's last update, as the window's
    ///     Reload does
    public func open(_ mergeRequest: MergeRequest, force: Bool = false) async {
        select(mergeRequest)
        let key = mergeRequest.reference
        var entry = entries[key] ?? Entry()
        if entry.isListing {
            return
        }
        if !force, state(of: mergeRequest).isCurrent {
            // Kept from before, without the diffs another selection dropped.
            await loadPage(1, of: mergeRequest)
            return
        }
        entry.isListing = true
        entry.failed = false
        // An older update's diffs don't fit the new list.
        entry.changes?.dropDiffs()
        entry.paging = ChangesPaging()
        entry.generation += 1
        let generation = entry.generation
        entries[key] = entry
        let services = services
        let source = DescriptionSource(mergeRequest)
        let answer = await run(key) { () -> ListAnswer in
            guard let client = try? await services.session().get().client else {
                return .noSession
            }
            guard let operation = GitLabOperation.changedFiles(of: source), let list = try? await client.send(operation) else {
                return .noList
            }
            return .list(list)
        }
        guard var entry = entries[key], entry.generation == generation else {
            return
        }
        entry.isListing = false
        switch answer {
        case nil:
            entries[key] = entry
            return
        case .noSession:
            entry.failed = true
            entries[key] = entry
            return
        case .noList:
            entry.changes = MergeRequestChanges(files: [], isComplete: false)
        case .list(let list):
            entry.changes = list
        }
        entry.changesUpdatedAt = mergeRequest.updatedAt
        entries[key] = entry
        await loadPage(1, of: mergeRequest)
    }

    /// Loads the diff of a file the card shows or unfolds, with its page, and the page half a page further down; without
    /// GitLab's list, the next page near the end of the files so far. A page on its way or loaded isn't asked again.
    ///
    /// - Parameters:
    ///   - mergeRequest: the selected merge request
    ///   - index: the file's place in the list, from 0
    public func loadDiff(of mergeRequest: MergeRequest, fileAt index: Int) async {
        guard recent.first == mergeRequest.reference, let entry = entries[mergeRequest.reference], !entry.isListing,
            let changes = entry.changes, !changes.isListOnly
        else {
            return
        }
        var pages: [Int] = []
        if changes.files.indices.contains(index), changes.files[index].content == .notLoaded,
            let page = entry.paging.page(forFileAt: index)
        {
            pages.append(page)
        }
        let ahead = index + ChangesPaging.pageSize / 2
        let aheadPage = ahead / ChangesPaging.pageSize + 1
        if changes.files.indices.contains(ahead), changes.files[ahead].content == .notLoaded,
            !entry.paging.loaded.contains(aheadPage), !entry.paging.inFlight.contains(aheadPage), !pages.contains(aheadPage)
        {
            pages.append(aheadPage)
        }
        if !changes.isComplete, index >= changes.files.count - 5, let next = entry.paging.nextPage, !pages.contains(next) {
            pages.append(next)
        }
        await withDiscardingTaskGroup { group in
            for page in pages {
                group.addTask { await self.loadPage(page, of: mergeRequest) }
            }
        }
    }

    private enum ListAnswer: Sendable {
        case list(MergeRequestChanges)
        /// GitLab didn't send the list: the pages bring the files
        case noList
        /// no token or no team values
        case noSession
    }

    private func loadPage(_ page: Int, of mergeRequest: MergeRequest) async {
        let key = mergeRequest.reference
        guard recent.first == key, var entry = entries[key], !entry.isListing, entry.changes?.isListOnly == false,
            !entry.paging.loaded.contains(page), !entry.paging.inFlight.contains(page)
        else {
            return
        }
        entry.paging.start(page)
        let generation = entry.generation
        entries[key] = entry
        let services = services
        let source = DescriptionSource(mergeRequest)
        let answer = await run(key) { () -> MergeRequestDiffsPage? in
            guard let client = try? await services.session().get().client else {
                return nil
            }
            return try? await client.diffsPage(of: source, page: page)
        }
        guard var entry = entries[key], entry.generation == generation else {
            return
        }
        let cancelled = answer == nil
        guard let diffs = answer ?? nil else {
            entry.paging.fail(page)
            // Without GitLab's list, the first page is the list: without it, nothing shows.
            if !cancelled, entry.changes?.files.isEmpty == true, entry.changes?.isComplete == false {
                entry.changes = nil
                entry.changesUpdatedAt = nil
                entry.failed = true
            }
            entries[key] = entry
            return
        }
        entry.paging.finish(page, nextPage: diffs.nextPage, totalPages: diffs.totalPages, isEmpty: diffs.files.isEmpty)
        entry.changes?.merge(diffs.files)
        if entry.paging.isDone {
            entry.changes?.settle()
        }
        entries[key] = entry
    }

    /// Runs requests in a task that selecting another merge request cancels.
    ///
    /// - Returns: the value; `nil` when the task was cancelled
    private func run<Value: Sendable>(_ key: String, _ work: @escaping @Sendable () async -> Value) async -> Value? {
        let id = UUID()
        let task = Task { await work() }
        running[key, default: [:]][id] = { task.cancel() }
        let value = await task.value
        running[key]?[id] = nil
        return task.isCancelled ? nil : value
    }
}
