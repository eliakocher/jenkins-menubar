import Foundation

/// A parsed `CODEOWNERS` file, and which owners it names for a list of changed paths (MR-15).
///
/// The rules are GitLab's (its Code Owners documentation; inferred from the docs, not run against a GitLab):
/// - `#` starts a comment; a line is a pattern followed by owners, or a section header;
/// - a section is `[Name]`, `^[Name]` (optional: its approval isn't required), `[Name][2]` (two approvals) and may
///   carry default owners (`[Name] @user`) that the pattern lines below it use when they name none; two sections with
///   the same name (the case doesn't count) are one section;
/// - a pattern works like a `.gitignore` one: without a leading `/` it matches in any directory (`*.java`,
///   `README.md`), with one it is anchored at the root; a trailing `/` matches everything inside the directory; `*`
///   doesn't cross a `/`, `**/` crosses any number of directories; `?`, `[abc]` and `{a,b}` work; `\ ` and `\#` are a
///   space and a `#` in a pattern;
/// - in each section the **last** matching pattern wins for a path; the sections are independent, so a path has an
///   owner per section;
/// - `!pattern` takes the matching files out of the section's owners.
public struct CodeOwnersFile: Hashable, Sendable {
    /// the sections in the file's order; the lines before the first header are the default section, with no name
    public var sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    /// Reads the text of a `CODEOWNERS` file; a line that isn't a pattern or a header is left out.
    ///
    /// - Parameter text: the file's text
    public init(parsing text: String) {
        var sections: [Section] = [Section(name: nil, isOptional: false, approvalsRequired: 1, defaultOwners: [], rules: [])]
        var current = 0
        for (offset, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if let header = SectionHeader(line) {
                if let existing = sections.firstIndex(where: {
                    $0.name?.caseInsensitiveCompare(header.name) == .orderedSame
                }) {
                    current = existing
                    sections[existing].isOptional = sections[existing].isOptional && header.isOptional
                    sections[existing].approvalsRequired = header.approvals ?? sections[existing].approvalsRequired
                    if !header.owners.isEmpty {
                        sections[existing].defaultOwners = header.owners
                    }
                } else {
                    sections.append(
                        Section(
                            name: header.name, isOptional: header.isOptional, approvalsRequired: header.approvals ?? 1,
                            defaultOwners: header.owners, rules: []))
                    current = sections.count - 1
                }
                continue
            }
            let tokens = Self.tokens(of: line)
            guard var pattern = tokens.first, !pattern.isEmpty else {
                continue
            }
            let isExclusion = pattern.hasPrefix("!")
            if isExclusion {
                pattern.removeFirst()
            }
            let owners = Self.owners(in: tokens.dropFirst())
            sections[current].rules.append(
                Rule(pattern: pattern, owners: owners.isEmpty ? sections[current].defaultOwners : owners, isExclusion: isExclusion,
                     line: offset + 1))
        }
        // An empty default section only adds noise.
        if sections[0].rules.isEmpty, sections.count > 1 {
            sections.removeFirst()
        }
        self.sections = sections
    }

    /// One section.
    public struct Section: Hashable, Sendable {
        /// the section's name as first written; `nil` for the lines before the first header
        public var name: String?
        /// whether approvals aren't required (`^[Name]`)
        public var isOptional: Bool
        /// how many approvals the section needs (`[Name][2]`)
        public var approvalsRequired: Int
        public var defaultOwners: [Owner]
        public var rules: [Rule]

        public init(name: String?, isOptional: Bool, approvalsRequired: Int, defaultOwners: [Owner], rules: [Rule]) {
            self.name = name
            self.isOptional = isOptional
            self.approvalsRequired = approvalsRequired
            self.defaultOwners = defaultOwners
            self.rules = rules
        }
    }

    /// One pattern line.
    public struct Rule: Hashable, Sendable {
        /// the pattern as written, without a leading `!`
        public var pattern: String
        /// the owners of the line, else the section's default owners
        public var owners: [Owner]
        /// a `!pattern` line: the files have no owner in this section
        public var isExclusion: Bool
        /// the line's number in the file, from 1
        public var line: Int

        public init(pattern: String, owners: [Owner], isExclusion: Bool = false, line: Int = 0) {
            self.pattern = pattern
            self.owners = owners
            self.isExclusion = isExclusion
            self.line = line
        }
    }

    /// Who owns files: a user, a group, an email address or a role.
    public enum Owner: Hashable, Sendable {
        /// `@username`
        case user(String)
        /// `@group/subgroup`: the app doesn't expand groups, GitLab's approval rules do
        case group(String)
        /// `name@example.com`
        case email(String)
        /// `@@maintainer`
        case role(String)

        /// Reads one owner token.
        ///
        /// - Parameter token: like `@jdoe`, `@group/team`, `@@developer` or `jdoe@example.com`
        /// - Returns: the owner, `nil` for a token that isn't one
        public init?(_ token: String) {
            if token.hasPrefix("@@") {
                let role = String(token.dropFirst(2))
                guard !role.isEmpty else { return nil }
                self = .role(role)
            } else if token.hasPrefix("@") {
                let name = String(token.dropFirst())
                guard !name.isEmpty else { return nil }
                self = name.contains("/") ? .group(name) : .user(name)
            } else if token.contains("@"), !token.hasSuffix("@") {
                self = .email(token)
            } else {
                return nil
            }
        }
    }

    /// A pattern of one section that owns some of the changed files.
    public struct Match: Hashable, Sendable {
        /// the section's name; `nil` for the default section
        public var section: String?
        public var isOptional: Bool
        public var approvalsRequired: Int
        public var pattern: String
        public var owners: [Owner]
        /// the changed paths the pattern won, in the order given
        public var paths: [String]

        public init(section: String?, isOptional: Bool, approvalsRequired: Int, pattern: String, owners: [Owner], paths: [String]) {
            self.section = section
            self.isOptional = isOptional
            self.approvalsRequired = approvalsRequired
            self.pattern = pattern
            self.owners = owners
            self.paths = paths
        }
    }

    /// Returns the patterns that own the changed paths: per section the last matching pattern of each path, a pattern
    /// once with all the paths it won. Paths nobody owns, and exclusions, give no match.
    ///
    /// - Parameter paths: the changed files' paths in the repository, like `core/src/Main.java`
    /// - Returns: the matches, in the file's order of sections and patterns
    public func matches(for paths: [String]) -> [Match] {
        var result: [Match] = []
        for section in sections {
            let globs = section.rules.map { Glob($0.pattern) }
            var won: [Int: [String]] = [:]
            for path in paths {
                let normalized = path.hasPrefix("/") ? path : "/" + path
                guard let index = globs.lastIndex(where: { $0.matches(normalized) }) else {
                    continue
                }
                if !section.rules[index].isExclusion, !section.rules[index].owners.isEmpty {
                    won[index, default: []].append(path)
                }
            }
            for index in won.keys.sorted() {
                result.append(
                    Match(
                        section: section.name, isOptional: section.isOptional, approvalsRequired: section.approvalsRequired,
                        pattern: section.rules[index].pattern, owners: section.rules[index].owners, paths: won[index] ?? []))
            }
        }
        return result
    }

    // MARK: Reading

    /// the fields of a section header line
    private struct SectionHeader {
        var name: String
        var isOptional: Bool
        var approvals: Int?
        var owners: [Owner]

        init?(_ line: String) {
            var rest = Substring(line)
            isOptional = rest.hasPrefix("^")
            if isOptional {
                rest = rest.dropFirst()
            }
            guard rest.hasPrefix("["), let close = rest.firstIndex(of: "]") else {
                return nil
            }
            name = rest[rest.index(after: rest.startIndex)..<close].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                return nil
            }
            rest = rest[rest.index(after: close)...]
            approvals = nil
            if rest.hasPrefix("["), let end = rest.firstIndex(of: "]"),
                let count = Int(rest[rest.index(after: rest.startIndex)..<end])
            {
                approvals = max(count, 1)
                rest = rest[rest.index(after: end)...]
            }
            // `[ab]*.java` is a pattern, not a header: after the brackets comes a space or nothing.
            guard rest.isEmpty || rest.first?.isWhitespace == true else {
                return nil
            }
            owners = CodeOwnersFile.owners(in: CodeOwnersFile.tokens(of: String(rest)))
        }
    }

    /// Splits a line at whitespace that isn't escaped; `\ ` stays a space inside a token and a comment ends the line.
    private static func tokens(of line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var iterator = line.makeIterator()
        var escaped = false
        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        while let character = iterator.next() {
            if escaped {
                // Everything but a space and a `#` keeps its backslash: the glob reads it.
                current.append(character == " " || character == "#" ? character : "\\")
                if character != " " && character != "#" {
                    current.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character.isWhitespace {
                flush()
            } else if character == "#", current.isEmpty {
                // A comment after the owners.
                return tokens
            } else {
                current.append(character)
            }
        }
        flush()
        return tokens
    }

    private static func owners(in tokens: some Sequence<String>) -> [Owner] {
        tokens.compactMap(Owner.init)
    }
}

// MARK: - Globs

/// One pattern of a `CODEOWNERS` file, ready to match paths that start with `/`.
struct Glob: Sendable {
    private enum Token: Sendable {
        case literal(Character)
        /// `?`: one character but `/`
        case one
        /// `*`: any characters but `/`
        case star
        /// `**` not before a `/`: any characters
        case any
        /// `**/` after a `/`: any number of directories, none too
        case directories
        case set([Character], isNegated: Bool)
    }

    /// the patterns the braces expand to, each as tokens
    private let alternatives: [[Token]]

    /// Reads a pattern: the leading `/` anchors it at the root, any other pattern gets `/**/`; a trailing `/` takes
    /// everything inside; `*` alone is every file.
    ///
    /// - Parameter pattern: the pattern as written in the file
    init(_ pattern: String) {
        var normalized = pattern == "*" ? "/**/*" : pattern
        if !normalized.hasPrefix("/") {
            normalized = "/**/" + normalized
        }
        if normalized.hasSuffix("/") {
            normalized += "**/*"
        }
        alternatives = Self.expandBraces(normalized).map(Self.tokens)
    }

    /// Returns whether a path matches; the path starts with `/`.
    func matches(_ path: String) -> Bool {
        let characters = Array(path)
        return alternatives.contains { Self.match($0[...], characters[...]) }
    }

    private static func match(_ tokens: ArraySlice<Token>, _ text: ArraySlice<Character>) -> Bool {
        guard let token = tokens.first else {
            return text.isEmpty
        }
        let rest = tokens.dropFirst()
        switch token {
        case .literal(let character):
            return text.first == character && match(rest, text.dropFirst())
        case .one:
            guard let first = text.first, first != "/" else { return false }
            return match(rest, text.dropFirst())
        case .set(let members, let isNegated):
            guard let first = text.first, first != "/" else { return false }
            return members.contains(first) != isNegated && match(rest, text.dropFirst())
        case .star:
            var remaining = text
            while true {
                if match(rest, remaining) { return true }
                guard let first = remaining.first, first != "/" else { return false }
                remaining = remaining.dropFirst()
            }
        case .any:
            var remaining = text
            while true {
                if match(rest, remaining) { return true }
                guard !remaining.isEmpty else { return false }
                remaining = remaining.dropFirst()
            }
        case .directories:
            var remaining = text
            while true {
                if match(rest, remaining) { return true }
                // One more directory: up to and including the next `/`.
                guard let slash = remaining.firstIndex(of: "/") else { return false }
                remaining = remaining[(slash + 1)...]
            }
        }
    }

    private static func tokens(of pattern: String) -> [Token] {
        let characters = Array(pattern)
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\" where index + 1 < characters.count:
                tokens.append(.literal(characters[index + 1]))
                index += 2
            case "*":
                var end = index
                while end < characters.count, characters[end] == "*" {
                    end += 1
                }
                if end - index >= 2 {
                    let afterSlash = end < characters.count && characters[end] == "/"
                    let atBoundary = index == 0 || characters[index - 1] == "/"
                    if afterSlash, atBoundary {
                        tokens.append(.directories)
                        end += 1
                    } else {
                        tokens.append(.any)
                    }
                } else {
                    tokens.append(.star)
                }
                index = end
            case "?":
                tokens.append(.one)
                index += 1
            case "[":
                if let close = characters[(index + 1)...].firstIndex(of: "]"), close > index + 1 {
                    var body = Array(characters[(index + 1)..<close])
                    let isNegated = body.first == "!" || body.first == "^"
                    if isNegated {
                        body.removeFirst()
                    }
                    tokens.append(.set(expandRanges(body), isNegated: isNegated))
                    index = close + 1
                } else {
                    tokens.append(.literal(character))
                    index += 1
                }
            default:
                tokens.append(.literal(character))
                index += 1
            }
        }
        return tokens
    }

    /// `a-c` as `a`, `b`, `c`
    private static func expandRanges(_ body: [Character]) -> [Character] {
        var members: [Character] = []
        var index = 0
        while index < body.count {
            if index + 2 < body.count, body[index + 1] == "-",
                let low = body[index].unicodeScalars.first?.value, let high = body[index + 2].unicodeScalars.first?.value, low <= high
            {
                members += (low...high).compactMap(Unicode.Scalar.init).map(Character.init)
                index += 3
            } else {
                members.append(body[index])
                index += 1
            }
        }
        return members
    }

    /// `{a,b}` as two patterns; braces nest, an unmatched one stays as it is
    private static func expandBraces(_ pattern: String) -> [String] {
        let characters = Array(pattern)
        guard let open = characters.firstIndex(of: "{") else {
            return [pattern]
        }
        var depth = 0
        var commas: [Int] = []
        var close: Int?
        for index in open..<characters.count {
            switch characters[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { close = index }
            case "," where depth == 1: commas.append(index)
            default: break
            }
            if close != nil { break }
        }
        guard let close else {
            return [pattern]
        }
        let prefix = String(characters[..<open])
        let suffix = String(characters[(close + 1)...])
        var bounds = [open] + commas + [close]
        bounds.sort()
        var results: [String] = []
        for pair in zip(bounds, bounds.dropFirst()) {
            let choice = String(characters[(pair.0 + 1)..<pair.1])
            results += expandBraces(prefix + choice + suffix)
        }
        return results
    }
}
