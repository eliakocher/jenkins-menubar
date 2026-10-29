import Foundation

/// A git checkout the app found in Settings → Repositories: one workspace, which is one task (WS-01).
public struct Checkout: Hashable, Sendable, Identifiable {
    /// the checkout's folder, absolute and standardized
    public var path: String
    /// the folder the pattern's `*` matched, like `develop3`, or a single folder's own name; `{name}` in the IDE
    /// command
    public var name: String
    /// the base branch of its entry in Settings
    public var baseBranch: String
    /// the Settings entry it was found by
    public var folder: RepositoryFolder.ID

    public init(path: String, name: String, baseBranch: String, folder: RepositoryFolder.ID) {
        self.path = path
        self.name = name
        self.baseBranch = baseBranch
        self.folder = folder
    }

    /// The path is the checkout's identity: the same folder found twice is one checkout.
    public var id: String { path }

    /// the folder as a file URL
    public var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
}

/// What one Settings entry found: its checkouts, or why none.
public struct FolderFindings: Hashable, Sendable {
    public var folder: RepositoryFolder.ID
    /// the checkouts, sorted by name as Finder sorts (`develop2` before `develop10`)
    public var checkouts: [Checkout]
    /// why nothing was found; `nil` when checkouts were
    public var problem: Problem?

    public init(folder: RepositoryFolder.ID, checkouts: [Checkout], problem: Problem? = nil) {
        self.folder = folder
        self.checkouts = checkouts
        self.problem = problem
    }

    /// Why an entry found no checkout.
    public enum Problem: Hashable, Sendable {
        /// the path is empty, or not absolute
        case notAbsolute
        /// a single folder that doesn't exist
        case missing
        /// a single folder without `.git`
        case notACheckout
        /// a pattern that matched no checkout
        case noMatches
        /// a base branch git could misread (``BranchNameRule``)
        case invalidBaseBranch

        /// the text under the entry in Settings
        public var message: String {
            switch self {
            case .notAbsolute: "Enter a full path, starting with / or ~"
            case .missing: "The folder doesn't exist"
            case .notACheckout: "Not a git checkout: the folder has no .git"
            case .noMatches: "No checkout matches"
            case .invalidBaseBranch: "The base branch isn't a valid branch name"
            }
        }
    }
}

/// Finds the checkouts of Settings → Repositories on disk (WS-01): a single folder, or a pattern like
/// `<parent>/*/<subfolder>` whose `*` matches one folder level. A checkout is a folder with `.git` in it, a folder or a
/// file (a worktree's). It only lists folders; it never runs git.
public enum WorkspaceDiscovery {
    /// the most checkouts one entry finds, so a pattern like `/*/*` can't make the app list the whole disk
    public static let maximumCheckouts = 100

    /// Finds the checkouts of every entry. A folder found by two entries counts once, for the first.
    ///
    /// - Parameters:
    ///   - folders: the entries of Settings → Repositories
    ///   - home: the home folder, for `~`
    ///   - fileManager: the file system
    /// - Returns: what each entry found, in the entries' order
    public static func find(
        _ folders: [RepositoryFolder], home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [FolderFindings] {
        var seen = Set<String>()
        return folders.map { folder in
            var findings = find(folder, home: home, fileManager: fileManager)
            findings.checkouts = findings.checkouts.filter { seen.insert($0.path).inserted }
            return findings
        }
    }

    /// Finds the checkouts of one entry.
    ///
    /// - Parameters:
    ///   - folder: the entry
    ///   - home: the home folder, for `~`
    ///   - fileManager: the file system
    /// - Returns: its checkouts, or why there are none
    public static func find(
        _ folder: RepositoryFolder, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> FolderFindings {
        guard BranchNameRule.isValid(folder.effectiveBaseBranch) else {
            return FolderFindings(folder: folder.id, checkouts: [], problem: .invalidBaseBranch)
        }
        guard let path = expand(folder.path, home: home) else {
            return FolderFindings(folder: folder.id, checkouts: [], problem: .notAbsolute)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.contains(where: isPattern) else {
            // A single folder: it is a checkout, or the entry says why not.
            guard isDirectory(path, fileManager) else {
                return FolderFindings(folder: folder.id, checkouts: [], problem: .missing)
            }
            guard isCheckout(path, fileManager) else {
                return FolderFindings(folder: folder.id, checkouts: [], problem: .notACheckout)
            }
            let name = components.last ?? path
            return FolderFindings(folder: folder.id, checkouts: [
                Checkout(path: path, name: name, baseBranch: folder.effectiveBaseBranch, folder: folder.id),
            ])
        }

        // Each candidate is a folder that exists, with the names its pattern components matched.
        var candidates: [(path: String, matched: [String])] = [("", [])]
        for component in components {
            var next: [(path: String, matched: [String])] = []
            for candidate in candidates {
                let parent = candidate.path.isEmpty ? "/" : candidate.path
                if isPattern(component) {
                    for name in subfolders(of: parent, matching: component, fileManager) {
                        next.append(("\(candidate.path)/\(name)", candidate.matched + [name]))
                    }
                } else {
                    let child = "\(candidate.path)/\(component)"
                    if isDirectory(child, fileManager) {
                        next.append((child, candidate.matched))
                    }
                }
                if next.count >= maximumCheckouts * 4 {
                    break
                }
            }
            candidates = next
        }
        let checkouts = candidates
            .filter { isCheckout($0.path, fileManager) }
            .prefix(maximumCheckouts)
            .map {
                Checkout(
                    path: $0.path, name: $0.matched.joined(separator: "/"), baseBranch: folder.effectiveBaseBranch,
                    folder: folder.id)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return FolderFindings(folder: folder.id, checkouts: checkouts, problem: checkouts.isEmpty ? .noMatches : nil)
    }

    /// Returns the entry to add for a folder picked with Add Folder…: the folder when it is a checkout; `<folder>/*` when
    /// its subfolders are checkouts; `<folder>/*/<name>` when they hold checkouts named alike, as several full clones
    /// side by side do; otherwise the folder, which then says why it finds nothing.
    ///
    /// - Parameters:
    ///   - folder: the picked folder, absolute
    ///   - home: the home folder, written as `~`
    ///   - fileManager: the file system
    /// - Returns: the path or pattern for the new entry
    public static func suggestedPath(
        for folder: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> String {
        let folder = standardized(folder)
        let shown = abbreviate(folder, home: home)
        if isCheckout(folder, fileManager) {
            return shown
        }
        let children = subfolders(of: folder, matching: "*", fileManager).prefix(200)
        if children.contains(where: { isCheckout("\(folder)/\($0)", fileManager) }) {
            return "\(shown)/*"
        }
        var counts: [String: Int] = [:]
        for child in children {
            for grandchild in subfolders(of: "\(folder)/\(child)", matching: "*", fileManager).prefix(200)
            where isCheckout("\(folder)/\(child)/\(grandchild)", fileManager) {
                counts[grandchild, default: 0] += 1
            }
        }
        // The name most clones share; the first by name on a tie, so the answer doesn't depend on the disk's order.
        if let best = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
            return "\(shown)/*/\(best.key)"
        }
        return shown
    }

    /// Returns the absolute, standardized path of an entry's text: `~` is the home folder.
    ///
    /// - Parameters:
    ///   - text: the path as typed
    ///   - home: the home folder
    /// - Returns: the path, without a trailing `/`; `nil` when it is empty or relative
    public static func expand(_ text: String, home: URL) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let homePath = standardized(home.path(percentEncoded: false))
        let expanded: String
        if trimmed == "~" {
            expanded = homePath
        } else if trimmed.hasPrefix("~/") {
            expanded = homePath + trimmed.dropFirst()
        } else if trimmed.hasPrefix("/") {
            expanded = trimmed
        } else {
            return nil
        }
        return standardized(expanded)
    }

    /// Returns a path with the home folder written as `~`, as Settings shows it.
    ///
    /// - Parameters:
    ///   - path: an absolute path
    ///   - home: the home folder
    /// - Returns: the path, `~/…` inside the home folder
    public static func abbreviate(_ path: String, home: URL) -> String {
        let homePath = standardized(home.path(percentEncoded: false))
        if path == homePath {
            return "~"
        }
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    // MARK: - The file system

    private static func isPattern(_ component: String) -> Bool {
        component.contains("*") || component.contains("?")
    }

    private static func standardized(_ path: String) -> String {
        var result = (path as NSString).standardizingPath
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func isDirectory(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// whether the folder has `.git`, a folder or a worktree's file
    private static func isCheckout(_ path: String, _ fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: "\(path)/.git")
    }

    /// The names of a folder's subfolders that match a pattern component, sorted; hidden ones only when the pattern
    /// starts with a dot.
    private static func subfolders(of path: String, matching pattern: String, _ fileManager: FileManager) -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: path) else {
            return []
        }
        return names
            .filter { !$0.hasPrefix(".") || pattern.hasPrefix(".") }
            .filter { fnmatch(pattern, $0, 0) == 0 }
            .filter { isDirectory("\(path)/\($0)", fileManager) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
