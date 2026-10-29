import Foundation

/// A local branch of a checkout, as `git for-each-ref` describes it (WS-07): how it stands to its remote branch and to
/// the base, and its last commit.
public struct LocalBranch: Hashable, Sendable, Identifiable {
    public var name: String
    /// whether the checkout has it checked out
    public var isCurrent: Bool
    /// the remote branch it tracks, like `origin/1234-fix`; `nil` without one
    public var upstream: String?
    /// whether the tracked remote branch is gone, as after a merge and a pruning fetch
    public var upstreamGone: Bool
    /// the commits it has that its remote branch doesn't; `nil` without a live remote branch
    public var aheadOfUpstream: Int?
    /// the commits its remote branch has that it doesn't; `nil` without a live remote branch
    public var behindUpstream: Int?
    /// the commits it has that `origin/<base>` doesn't; `nil` when git can't tell
    public var aheadOfBase: Int?
    /// the commits `origin/<base>` has that it doesn't; `nil` when git can't tell
    public var behindBase: Int?
    /// the last commit's subject
    public var subject: String
    /// the last commit's committer date
    public var committedAt: Date
    /// whether `origin` has a branch of this name, tracked or not: the branch can open a merge request
    public var isPushed: Bool

    public var id: String { name }

    public init(
        name: String, isCurrent: Bool = false, upstream: String? = nil, upstreamGone: Bool = false,
        aheadOfUpstream: Int? = nil, behindUpstream: Int? = nil, aheadOfBase: Int? = nil, behindBase: Int? = nil,
        subject: String = "", committedAt: Date = Date(timeIntervalSince1970: 0), isPushed: Bool = false
    ) {
        self.name = name
        self.isCurrent = isCurrent
        self.upstream = upstream
        self.upstreamGone = upstreamGone
        self.aheadOfUpstream = aheadOfUpstream
        self.behindUpstream = behindUpstream
        self.aheadOfBase = aheadOfBase
        self.behindBase = behindBase
        self.subject = subject
        self.committedAt = committedAt
        self.isPushed = isPushed
    }

    /// the separator between the fields of ``GitReader/Command/localBranches(base:)``: ASCII's unit separator, which a
    /// commit subject can't hold
    static let separator: Character = "\u{1F}"

    /// Reads the output of ``GitReader/Command/localBranches(base:)``. A line that doesn't have the fields is skipped.
    /// ``isPushed`` is only true for a branch with a live upstream; ``GitReader`` adds the ones whose `origin/<name>`
    /// exists without tracking.
    ///
    /// - Parameter output: the output, one branch per line
    /// - Returns: the branches in the output's order
    public static func parse(_ output: String) -> [LocalBranch] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: separator, maxSplits: 6, omittingEmptySubsequences: false)
            guard fields.count == 7, !fields[1].isEmpty else {
                return nil
            }
            var branch = LocalBranch(name: String(fields[1]), isCurrent: fields[0] == "*")
            if !fields[2].isEmpty {
                branch.upstream = String(fields[2])
                let track = String(fields[3])
                if track == "gone" {
                    branch.upstreamGone = true
                } else {
                    let counts = trackCounts(track)
                    branch.aheadOfUpstream = counts.ahead
                    branch.behindUpstream = counts.behind
                    branch.isPushed = true
                }
            }
            branch.committedAt = Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0)
            if let counts = GitReader.counts(String(fields[5])), counts.count == 2 {
                branch.aheadOfBase = counts[0]
                branch.behindBase = counts[1]
            }
            branch.subject = String(fields[6])
            return branch
        }
    }

    /// Reads `%(upstream:track,nobracket)`: "ahead 2, behind 1", "ahead 2", "behind 1", or empty for in sync.
    static func trackCounts(_ track: String) -> (ahead: Int, behind: Int) {
        var ahead = 0
        var behind = 0
        for part in track.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else {
                continue
            }
            if words[0] == "ahead" {
                ahead = count
            } else if words[0] == "behind" {
                behind = count
            }
        }
        return (ahead, behind)
    }

    /// Returns the branches that have no merge request yet: the base branch is no task, and a branch that is the source
    /// branch of a loaded merge request has one (WS-06).
    ///
    /// - Parameters:
    ///   - branches: the checkout's local branches
    ///   - base: the checkout's base branch
    ///   - mergeRequests: the loaded merge requests
    /// - Returns: the branches without a merge request, in their order
    public static func withoutMergeRequest(
        _ branches: [LocalBranch], base: String, mergeRequests: [MergeRequest]
    ) -> [LocalBranch] {
        let taken = Set(mergeRequests.compactMap(\.sourceBranch))
        return branches.filter { $0.name != base && !taken.contains($0.name) }
    }
}

/// A checkout's local branches as last read (WS-06).
public struct LocalBranches: Hashable, Sendable {
    /// the branches, the most recently committed first, at most ``maximum``
    public var branches: [LocalBranch]
    /// how many local branches the checkout has
    public var total: Int
    /// when the branches were read
    public var readAt: Date

    /// the most branches the app reads details for; a checkout can have hundreds of old ones
    public static let maximum = 40

    public init(branches: [LocalBranch], total: Int, readAt: Date) {
        self.branches = branches
        self.total = total
        self.readAt = readAt
    }
}

/// A checkout's local branches, or why git couldn't list them.
public enum LocalBranchesReading: Hashable, Sendable {
    case read(LocalBranches)
    case failed(String)
}

/// The page that opens a merge request for a pushed branch (WS-06).
public enum NewMergeRequestLink {
    /// Returns `<gitlab>/<project>/-/merge_requests/new?merge_request[source_branch]=…&merge_request[target_branch]=…`,
    /// the page GitLab prints after a push, with the source branch prefilled. GitLab's docs don't list these
    /// parameters; they are the ones its own link after a push carries.
    ///
    /// - Parameters:
    ///   - gitLab: the GitLab instance
    ///   - project: the project's full path, like `group/project`
    ///   - source: the pushed branch
    ///   - target: the branch it merges into, the checkout's base branch
    /// - Returns: the link; `nil` without a project or when the URL can't be built
    public static func url(gitLab: URL, project: String, source: String, target: String) -> URL? {
        let path = project.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !path.isEmpty else {
            return nil
        }
        var base = gitLab.absoluteString
        while base.hasSuffix("/") {
            base.removeLast()
        }
        let query = [("merge_request[source_branch]", source), ("merge_request[target_branch]", target)]
            .map { "\(encode($0.0))=\(encode($0.1))" }
            .joined(separator: "&")
        return URL(string: "\(base)/\(path)/-/merge_requests/new?\(query)")
    }

    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

/// The branch name of a work item, GitLab's "Create branch" naming: `<number>-<title-as-slug>` (WS-08).
public enum BranchSlug {
    /// the longest branch name the app makes
    public static let maximumLength = 100

    /// Returns the branch name of a work item: the number, a dash, and the title as lowercase ASCII words joined by
    /// dashes. Accents are dropped (`é` is `e`, `ß` is `ss`), anything else that isn't a letter or digit separates
    /// words, runs of separators are one dash, and the name is cut at 100 characters without ending in a dash. A title
    /// without letters or digits leaves the number alone.
    ///
    /// - Parameters:
    ///   - number: the work item's number, 1 or more
    ///   - title: the work item's title; may be empty
    /// - Returns: the branch name; `nil` for a number below 1
    public static func name(number: Int, title: String) -> String? {
        guard number > 0 else {
            return nil
        }
        let prefix = "\(number)"
        let slug = slug(of: title)
        guard !slug.isEmpty else {
            return prefix
        }
        var name = "\(prefix)-\(slug)"
        if name.count > maximumLength {
            name = String(name.prefix(maximumLength))
            while name.hasSuffix("-") {
                name.removeLast()
            }
        }
        return name
    }

    /// The title as lowercase words of `a-z0-9` joined by single dashes.
    static func slug(of title: String) -> String {
        var transliterated = ""
        for character in title {
            if let special = specials[character] {
                transliterated += special
            } else {
                transliterated.append(character)
            }
        }
        let folded = transliterated.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        var words: [String] = []
        var word = ""
        for scalar in folded.lowercased().unicodeScalars {
            if (0x30...0x39).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty {
            words.append(word)
        }
        return words.joined(separator: "-")
    }

    /// letters Unicode's accent folding keeps, spelled the way Rails' `parameterize` (GitLab's) does
    private static let specials: [Character: String] = [
        "ß": "ss", "æ": "ae", "Æ": "ae", "ø": "o", "Ø": "o", "œ": "oe", "Œ": "oe", "ł": "l", "Ł": "l", "đ": "d",
        "Đ": "d", "þ": "th", "Þ": "th", "ð": "d", "Ð": "d",
    ]
}
