import CryptoKit
import Foundation

// MARK: - The refs and the position

/// The three commits a merge request's diff is taken between, which every comment on the diff names so GitLab knows
/// which version of the file the line belongs to (CMT-03).
///
/// `GraphQL MergeRequest.diffRefs { baseSha headSha startSha }` (GitLab's reference, inferred): `baseSha` is the merge
/// base, `startSha` the target branch's head at the time of the diff, `headSha` the source branch's head.
public struct DiffRefs: Codable, Hashable, Sendable {
    public var baseSha: String
    public var headSha: String
    public var startSha: String

    public init(baseSha: String, headSha: String, startSha: String) {
        self.baseSha = baseSha
        self.headSha = headSha
        self.startSha = startSha
    }
}

/// Where a comment on the diff goes: the file in its old and new name and the line, with the commits (CMT-03).
///
/// What GitLab expects, from its documentation (inferred, never sent to a real GitLab by the author): an added line has
/// only `newLine`, a removed line only `oldLine`, an unchanged line both; the paths are both set, equal unless the file
/// was renamed. A comment on several lines is placed on the last one, with the first in ``range``.
public struct DiffPosition: Codable, Hashable, Sendable {
    public var refs: DiffRefs
    public var oldPath: String
    public var newPath: String
    /// the line in the old file; `nil` for an added line
    public var oldLine: Int?
    /// the line in the new file; `nil` for a removed line
    public var newLine: Int?
    /// the first and the last line of a comment on several lines; `nil` for one line
    public var range: LineRange?

    public init(
        refs: DiffRefs, oldPath: String, newPath: String, oldLine: Int?, newLine: Int?, range: LineRange? = nil
    ) {
        self.refs = refs
        self.oldPath = oldPath
        self.newPath = newPath
        self.oldLine = oldLine
        self.newLine = newLine
        self.range = range
    }

    /// The lines of a comment on several of them.
    public struct LineRange: Codable, Hashable, Sendable {
        public var start: Endpoint
        public var end: Endpoint

        public init(start: Endpoint, end: Endpoint) {
            self.start = start
            self.end = end
        }
    }

    /// One end of a ``LineRange``, as GitLab's `line_range` names it.
    public struct Endpoint: Codable, Hashable, Sendable {
        /// `<sha1 of the path>_<old>_<new>`, GitLab's key of a line of a diff (inferred from `Gitlab::Git.diff_line_code`)
        public var lineCode: String
        /// `.old` for a removed line, `.new` for an added one, `nil` for an unchanged one
        public var side: Side?
        public var oldLine: Int?
        public var newLine: Int?

        public init(lineCode: String, side: Side?, oldLine: Int?, newLine: Int?) {
            self.lineCode = lineCode
            self.side = side
            self.oldLine = oldLine
            self.newLine = newLine
        }
    }

    public enum Side: String, Codable, Hashable, Sendable {
        case old
        case new
    }
}

// MARK: - The selection and the builder

/// The lines the user selected in one file's diff: indices into a hunk's lines, both included (CMT-03).
public struct DiffLineSelection: Hashable, Sendable {
    /// the hunk, as its index in the file's hunks
    public var hunk: Int
    /// the first selected line, as its index in the hunk's lines
    public var first: Int
    /// the last selected line; the same as ``first`` for one line
    public var last: Int

    /// - Parameters:
    ///   - hunk: the hunk's index
    ///   - first: a selected line's index; the ends may come in either order
    ///   - last: the other end
    public init(hunk: Int, first: Int, last: Int? = nil) {
        self.hunk = hunk
        self.first = first
        self.last = last ?? first
    }
}

/// Why a selection has no position.
public enum DiffPositionError: Error, Hashable, Sendable, CustomStringConvertible {
    /// the file's diff isn't loaded, or is binary or too big to show: no line to point at
    case noDiff
    /// the hunk or a line isn't there
    case outOfRange

    public var description: String {
        switch self {
        case .noDiff: "This file's diff isn't shown, so there is no line to comment on."
        case .outOfRange: "The selected lines aren't in the diff."
        }
    }
}

/// Builds the position of a comment from lines selected in a merge request's parsed diff (CMT-03).
public enum DiffPositionBuilder {
    /// Returns the position of a selection.
    ///
    /// - Parameters:
    ///   - file: the changed file with its loaded hunks
    ///   - selection: the selected lines of one hunk; several lines make a range, placed on the last line
    ///   - refs: the merge request's `diffRefs`
    /// - Returns: the position
    /// - Throws: ``DiffPositionError`` when the file shows no diff or the selection isn't in it
    public static func position(
        in file: MergeRequestChanges.FileChange, selection: DiffLineSelection, refs: DiffRefs
    ) throws -> DiffPosition {
        guard case .hunks(let hunks) = file.content else {
            throw DiffPositionError.noDiff
        }
        guard hunks.indices.contains(selection.hunk) else {
            throw DiffPositionError.outOfRange
        }
        let hunk = hunks[selection.hunk]
        let (low, high) = (min(selection.first, selection.last), max(selection.first, selection.last))
        guard low >= 0, high < hunk.lines.count else {
            throw DiffPositionError.outOfRange
        }
        let counters = Self.counters(of: hunk)
        // GitLab names a deleted file by its old path on both sides, which the diff's own paths already do.
        let paths = (file.oldPath, file.newPath)
        let end = endpoint(hunk.lines[high], counters: counters[high], path: file.path)
        var range: DiffPosition.LineRange?
        if low != high {
            range = .init(start: endpoint(hunk.lines[low], counters: counters[low], path: file.path), end: end)
        }
        let line = hunk.lines[high]
        return DiffPosition(
            refs: refs, oldPath: paths.0, newPath: paths.1,
            oldLine: line.kind == .added ? nil : line.oldNumber, newLine: line.kind == .removed ? nil : line.newNumber,
            range: range)
    }

    /// The counters of the old and the new file at each line of a hunk, as GitLab's diff parser has them when it
    /// reaches the line: the hunk's starts, each counter moving on after an unchanged line, and after a removed line
    /// for the old one, an added line for the new one (inferred from `Gitlab::Diff::Parser`).
    static func counters(of hunk: DiffHunk) -> [(old: Int, new: Int)] {
        var old = hunk.oldStart
        var new = hunk.newStart
        return hunk.lines.map { line in
            defer {
                switch line.kind {
                case .context:
                    old += 1
                    new += 1
                case .removed: old += 1
                case .added: new += 1
                }
            }
            return (old, new)
        }
    }

    private static func endpoint(_ line: DiffLine, counters: (old: Int, new: Int), path: String) -> DiffPosition.Endpoint {
        DiffPosition.Endpoint(
            lineCode: "\(sha1(path))_\(counters.old)_\(counters.new)",
            side: line.kind == .removed ? .old : line.kind == .added ? .new : nil,
            oldLine: line.kind == .added ? nil : line.oldNumber, newLine: line.kind == .removed ? nil : line.newNumber)
    }

    private static func sha1(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Variables and bodies

extension DiffPosition {
    /// GraphQL's `DiffPositionInput` for `createDiffNote` (inferred from GitLab's reference): `baseSha`, `headSha`,
    /// `startSha`, `paths { oldPath newPath }`, `oldLine`, `newLine`. It has no line range, so ``range`` isn't in it:
    /// a comment on several lines goes by REST (``GitLabClient/addDiffThread(_:body:to:)``).
    var graphQLInput: GraphQLValue {
        var fields: [(String, GraphQLValue)] = [
            ("baseSha", .string(refs.baseSha)), ("headSha", .string(refs.headSha)), ("startSha", .string(refs.startSha)),
            ("paths", .object([("oldPath", .string(oldPath)), ("newPath", .string(newPath))])),
        ]
        if let oldLine {
            fields.append(("oldLine", .int(oldLine)))
        }
        if let newLine {
            fields.append(("newLine", .int(newLine)))
        }
        return .object(fields)
    }

    /// REST's `position` of `POST …/discussions` and `…/draft_notes` (GitLab's documentation, inferred), with
    /// `line_range` for several lines.
    var restPosition: GraphQLValue {
        var fields: [(String, GraphQLValue)] = [
            ("position_type", .string("text")), ("base_sha", .string(refs.baseSha)), ("head_sha", .string(refs.headSha)),
            ("start_sha", .string(refs.startSha)), ("old_path", .string(oldPath)), ("new_path", .string(newPath)),
        ]
        if let oldLine {
            fields.append(("old_line", .int(oldLine)))
        }
        if let newLine {
            fields.append(("new_line", .int(newLine)))
        }
        if let range {
            func end(_ endpoint: Endpoint) -> GraphQLValue {
                var parts: [(String, GraphQLValue)] = [("line_code", .string(endpoint.lineCode))]
                if let side = endpoint.side {
                    parts.append(("type", .string(side.rawValue)))
                }
                if let line = endpoint.oldLine {
                    parts.append(("old_line", .int(line)))
                }
                if let line = endpoint.newLine {
                    parts.append(("new_line", .int(line)))
                }
                return .object(parts)
            }
            fields.append(("line_range", .object([("start", end(range.start)), ("end", end(range.end))])))
        }
        return .object(fields)
    }
}
