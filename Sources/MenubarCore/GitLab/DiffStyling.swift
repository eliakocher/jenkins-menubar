import Foundation

/// A diff line cut into the pieces the detail colors (MR-11): each piece's syntax kind and whether it is the part of
/// the line that changed against its partner line.
public struct StyledLine: Hashable, Sendable {
    public var line: DiffLine
    public var segments: [Segment]

    public init(line: DiffLine, segments: [Segment]) {
        self.line = line
        self.segments = segments
    }

    /// A run of characters with one style.
    public struct Segment: Hashable, Sendable {
        public var text: String
        /// the syntax kind; `nil` for plain code
        public var token: CodeToken?
        /// whether the run is in the part of a removed or added line that differs from its partner
        public var isChanged: Bool

        public init(text: String, token: CodeToken? = nil, isChanged: Bool = false) {
            self.text = text
            self.token = token
            self.isChanged = isChanged
        }
    }
}

/// A row of the side-by-side diff: the old line on the left, the new on the right, either missing.
public struct SplitRow: Hashable, Sendable {
    public var left: StyledLine?
    public var right: StyledLine?

    public init(left: StyledLine?, right: StyledLine?) {
        self.left = left
        self.right = right
    }
}

/// What a piece of code is, for its color.
public enum CodeToken: Hashable, Sendable {
    case keyword
    case string
    case comment
    case number
    /// a type: a capitalized name in the languages that capitalize types
    case type
    /// an annotation, attribute, variable or key: `@MainActor`, `$HOME`, a YAML key, an XML attribute
    case attribute
}

/// Styles a file's hunks for the detail: syntax colors by the file's language, the changed part of paired lines, and
/// the side-by-side rows.
public enum DiffStyling {
    /// Returns each hunk's lines, styled.
    ///
    /// Each side is read in order, so a block comment or a multi-line string opened on an old or new line goes on in the
    /// lines after it. A run of removed lines followed by added lines pairs them one by one, and a pair that keeps a
    /// common start or end marks only the middle as changed (not when nearly all of the line changed).
    ///
    /// - Parameters:
    ///   - hunks: the file's hunks
    ///   - path: the file's path, whose name picks the language
    public static func style(_ hunks: [DiffHunk], path: String) -> [[StyledLine]] {
        let language = CodeLanguage(path: path)
        var oldState = Lexer.State()
        var newState = Lexer.State()
        return hunks.map { hunk in
            // The hunks are apart: a state carried over a gap would color the wrong lines.
            oldState = Lexer.State()
            newState = Lexer.State()
            let changed = changedRanges(hunk.lines)
            return hunk.lines.enumerated().map { index, line in
                let tokens: [Lexer.Token]
                switch line.kind {
                case .context:
                    tokens = Lexer.tokens(of: line.text, language: language, state: &newState)
                    _ = Lexer.tokens(of: line.text, language: language, state: &oldState)
                case .removed:
                    tokens = Lexer.tokens(of: line.text, language: language, state: &oldState)
                case .added:
                    tokens = Lexer.tokens(of: line.text, language: language, state: &newState)
                }
                return StyledLine(line: line, segments: segments(of: line.text, tokens: tokens, changed: changed[index]))
            }
        }
    }

    /// Returns the side-by-side rows of a hunk's styled lines: a context line on both sides, a run of removed lines next
    /// to the run of added lines after it, the shorter run padded.
    public static func split(_ lines: [StyledLine]) -> [SplitRow] {
        var rows: [SplitRow] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.line.kind != .context else {
                rows.append(SplitRow(left: line, right: line))
                index += 1
                continue
            }
            var removed: [StyledLine] = []
            var added: [StyledLine] = []
            while index < lines.count, lines[index].line.kind == .removed {
                removed.append(lines[index])
                index += 1
            }
            while index < lines.count, lines[index].line.kind == .added {
                added.append(lines[index])
                index += 1
            }
            for row in 0..<max(removed.count, added.count) {
                rows.append(SplitRow(left: row < removed.count ? removed[row] : nil, right: row < added.count ? added[row] : nil))
            }
        }
        return rows
    }

    // MARK: The changed part

    /// the changed part's share of the longer line above which the whole line counts as changed
    static let wholeLineShare = 0.7

    /// Returns, for each line, the character range that differs from its partner, or `nil`.
    static func changedRanges(_ lines: [DiffLine]) -> [Range<Int>?] {
        var ranges = [Range<Int>?](repeating: nil, count: lines.count)
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else {
                index += 1
                continue
            }
            let removedStart = index
            while index < lines.count, lines[index].kind == .removed {
                index += 1
            }
            let addedStart = index
            while index < lines.count, lines[index].kind == .added {
                index += 1
            }
            let pairs = min(addedStart - removedStart, index - addedStart)
            for pair in 0..<pairs {
                if let (old, new) = changed(Array(lines[removedStart + pair].text), Array(lines[addedStart + pair].text)) {
                    ranges[removedStart + pair] = old
                    ranges[addedStart + pair] = new
                }
            }
        }
        return ranges
    }

    /// The middle of two lines between their common start and end; `nil` when they share neither, or nearly all
    /// changed.
    static func changed(_ old: [Character], _ new: [Character]) -> (Range<Int>, Range<Int>)? {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let oldRange = prefix..<(old.count - suffix)
        let newRange = prefix..<(new.count - suffix)
        let longer = max(old.count, new.count)
        guard prefix + suffix > 0, longer > 0,
            Double(max(oldRange.count, newRange.count)) / Double(longer) <= wholeLineShare
        else {
            return nil
        }
        return (oldRange, newRange)
    }

    // MARK: Segments

    /// Cuts a line at every token edge and at the changed range's edges.
    static func segments(of text: String, tokens: [Lexer.Token], changed: Range<Int>?) -> [StyledLine.Segment] {
        let characters = Array(text)
        guard !characters.isEmpty else {
            return []
        }
        var kinds = [CodeToken?](repeating: nil, count: characters.count)
        for token in tokens {
            for offset in token.range.clamped(to: 0..<characters.count) {
                kinds[offset] = token.kind
            }
        }
        var segments: [StyledLine.Segment] = []
        var start = 0
        for offset in 1...characters.count {
            let isEdge =
                offset == characters.count || kinds[offset] != kinds[start]
                || (changed?.contains(offset) ?? false) != (changed?.contains(start) ?? false)
            if isEdge {
                segments.append(
                    StyledLine.Segment(
                        text: String(characters[start..<offset]), token: kinds[start], isChanged: changed?.contains(start) ?? false))
                start = offset
            }
        }
        return segments
    }
}

// MARK: - Languages

/// The languages the diff colors, by the file's name; others show without syntax colors.
public enum CodeLanguage: Hashable, Sendable {
    case swift
    /// Kotlin, Java, Groovy (a Jenkinsfile, Gradle), Scala, C#
    case jvm
    /// JavaScript and TypeScript
    case script
    case go
    case python
    case shell
    case json
    case yaml
    /// XML and HTML
    case markup
    case css
    case plain

    /// Returns the language of a file, by its extension or its name.
    public init(path: String) {
        let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        let ext = name.contains(".") ? String(name.split(separator: ".").last ?? "") : ""
        switch ext {
        case "swift": self = .swift
        case "kt", "kts", "java", "groovy", "gradle", "scala", "cs": self = .jvm
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts": self = .script
        case "go": self = .go
        case "py": self = .python
        case "sh", "bash", "zsh", "command": self = .shell
        case "json", "jsonc": self = .json
        case "yml", "yaml": self = .yaml
        case "xml", "html", "htm", "plist", "svg", "xsd", "pom": self = .markup
        case "css", "scss", "less": self = .css
        default:
            switch name {
            case "jenkinsfile": self = .jvm
            case "dockerfile", "makefile", ".gitlab-ci": self = .shell
            default: self = .plain
            }
        }
    }
}

// MARK: - The lexer

/// A small lexer for diff lines: comments, strings, numbers, keywords, capitalized types and annotations. It reads a
/// line at a time, carrying an open block comment or multi-line string to the next line.
enum Lexer {
    struct Token: Hashable {
        var range: Range<Int>
        var kind: CodeToken
    }

    /// What a line leaves open for the next.
    struct State: Hashable {
        /// the end of an open block comment, like `*/`
        var commentEnd: String?
        /// the end of an open multi-line string, like `"""`
        var stringEnd: String?
    }

    private struct Rules {
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var quotes: Set<Character> = ["\"", "'"]
        var tripleQuotes: [String] = []
        var keywords: Set<String> = []
        var capitalizedTypes = false
        /// the characters that start an annotation or attribute: `@`, `$`
        var marks: Set<Character> = []
        var yamlKeys = false
        var markupTags = false
    }

    static func tokens(of line: String, language: CodeLanguage, state: inout State) -> [Token] {
        guard language != .plain else {
            return []
        }
        let rules = rules(of: language)
        let text = Array(line)
        var tokens: [Token] = []
        var index = 0

        func starts(_ word: String, at offset: Int) -> Bool {
            let characters = Array(word)
            guard offset + characters.count <= text.count else {
                return false
            }
            return Array(text[offset..<(offset + characters.count)]) == characters
        }

        /// the offset after `end`, from `offset`; the line's end when it isn't there
        func find(_ end: String, from offset: Int) -> Int? {
            var position = offset
            while position < text.count {
                if starts(end, at: position) {
                    return position + end.count
                }
                position += 1
            }
            return nil
        }

        while index < text.count {
            if let end = state.commentEnd {
                let stop = find(end, from: index)
                tokens.append(Token(range: index..<(stop ?? text.count), kind: .comment))
                state.commentEnd = stop == nil ? end : nil
                index = stop ?? text.count
                continue
            }
            if let end = state.stringEnd {
                let stop = find(end, from: index)
                tokens.append(Token(range: index..<(stop ?? text.count), kind: .string))
                state.stringEnd = stop == nil ? end : nil
                index = stop ?? text.count
                continue
            }
            let character = text[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            if rules.lineComments.contains(where: { starts($0, at: index) })
                && (character != "#" || index == 0 || text[index - 1].isWhitespace)
            {
                tokens.append(Token(range: index..<text.count, kind: .comment))
                break
            }
            if let block = rules.blockComment, starts(block.open, at: index) {
                let stop = find(block.close, from: index + block.open.count)
                tokens.append(Token(range: index..<(stop ?? text.count), kind: .comment))
                state.commentEnd = stop == nil ? block.close : nil
                index = stop ?? text.count
                continue
            }
            if let triple = rules.tripleQuotes.first(where: { starts($0, at: index) }) {
                let stop = find(triple, from: index + triple.count)
                tokens.append(Token(range: index..<(stop ?? text.count), kind: .string))
                state.stringEnd = stop == nil ? triple : nil
                index = stop ?? text.count
                continue
            }
            if rules.quotes.contains(character) {
                var position = index + 1
                while position < text.count, text[position] != character {
                    position += text[position] == "\\" ? 2 : 1
                }
                let stop = min(position + 1, text.count)
                tokens.append(Token(range: index..<stop, kind: .string))
                index = stop
                continue
            }
            if character.isNumber, index == 0 || !isIdentifier(text[index - 1]) {
                var position = index + 1
                while position < text.count, text[position].isHexDigit || "xX._oObB".contains(text[position]) {
                    position += 1
                }
                tokens.append(Token(range: index..<position, kind: .number))
                index = position
                continue
            }
            if rules.markupTags, character == "<" {
                var position = index + 1
                if position < text.count, "/?!".contains(text[position]) {
                    position += 1
                }
                let nameStart = position
                while position < text.count, isIdentifier(text[position]) || "-:.".contains(text[position]) {
                    position += 1
                }
                if position > nameStart {
                    tokens.append(Token(range: index..<position, kind: .keyword))
                    index = position
                    continue
                }
            }
            if rules.marks.contains(character), index + 1 < text.count, isIdentifierStart(text[index + 1]) || text[index + 1] == "{" {
                var position = index + 1
                while position < text.count, isIdentifier(text[position]) || "{}".contains(text[position]) {
                    position += 1
                }
                tokens.append(Token(range: index..<position, kind: .attribute))
                index = position
                continue
            }
            if isIdentifierStart(character) {
                var position = index + 1
                while position < text.count, isIdentifier(text[position]) || (rules.yamlKeys && "-.".contains(text[position])) {
                    position += 1
                }
                let word = String(text[index..<position])
                let next = text[position...].first { !$0.isWhitespace }
                if rules.keywords.contains(word) {
                    tokens.append(Token(range: index..<position, kind: .keyword))
                } else if rules.yamlKeys, next == ":", text[..<index].allSatisfy({ $0.isWhitespace || $0 == "-" }) {
                    tokens.append(Token(range: index..<position, kind: .attribute))
                } else if rules.markupTags, next == "=" {
                    tokens.append(Token(range: index..<position, kind: .attribute))
                } else if rules.capitalizedTypes, character.isUppercase, word.contains(where: \.isLowercase) {
                    tokens.append(Token(range: index..<position, kind: .type))
                }
                index = position
                continue
            }
            index += 1
        }
        return tokens
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func rules(of language: CodeLanguage) -> Rules {
        let cLike = (open: "/*", close: "*/")
        switch language {
        case .swift:
            return Rules(
                lineComments: ["//"], blockComment: cLike, quotes: ["\""], tripleQuotes: ["\"\"\""],
                keywords: [
                    "let", "var", "func", "class", "struct", "enum", "protocol", "extension", "import", "return", "if", "else",
                    "guard", "switch", "case", "default", "for", "in", "while", "repeat", "break", "continue", "throw",
                    "throws", "rethrows", "try", "catch", "do", "async", "await", "actor", "public", "private", "internal",
                    "fileprivate", "open", "package", "static", "final", "override", "init", "deinit", "self", "Self", "super",
                    "nil", "true", "false", "some", "any", "where", "typealias", "associatedtype", "mutating", "nonisolated",
                    "inout", "defer", "is", "as", "subscript", "lazy", "weak", "unowned", "get", "set", "willSet", "didSet",
                    "convenience", "required", "operator", "consuming", "borrowing", "sending", "isolated",
                ],
                capitalizedTypes: true, marks: ["@", "#"])
        case .jvm:
            return Rules(
                lineComments: ["//"], blockComment: cLike, tripleQuotes: ["\"\"\"", "'''"],
                keywords: [
                    "package", "import", "class", "interface", "object", "enum", "fun", "val", "var", "void", "int", "long",
                    "boolean", "double", "float", "char", "byte", "short", "return", "if", "else", "when", "for", "while", "do",
                    "break", "continue", "throw", "throws", "try", "catch", "finally", "new", "this", "super", "null", "true",
                    "false", "public", "private", "protected", "internal", "static", "final", "abstract", "override", "open",
                    "data", "sealed", "companion", "in", "is", "as", "def", "extends", "implements", "instanceof",
                    "synchronized", "volatile", "transient", "const", "lateinit", "suspend", "inline", "typealias", "assert",
                    "default", "switch", "case", "record", "yield", "it", "pipeline", "stage", "stages", "steps",
                    "agent", "node", "sh",
                ],
                capitalizedTypes: true, marks: ["@"])
        case .script:
            return Rules(
                lineComments: ["//"], blockComment: cLike, quotes: ["\"", "'", "`"],
                keywords: [
                    "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "break", "continue",
                    "switch", "case", "default", "throw", "try", "catch", "finally", "new", "this", "super", "null",
                    "undefined", "true", "false", "class", "extends", "import", "export", "from", "as", "async", "await",
                    "yield", "typeof", "instanceof", "in", "of", "void", "delete", "interface", "type", "enum", "implements",
                    "public", "private", "protected", "readonly", "static", "abstract", "declare", "namespace", "keyof",
                    "any", "unknown", "never", "string", "number", "boolean",
                ],
                capitalizedTypes: true, marks: ["@"])
        case .go:
            return Rules(
                lineComments: ["//"], blockComment: cLike, quotes: ["\"", "'", "`"],
                keywords: [
                    "func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer",
                    "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "select", "nil",
                    "true", "false", "string", "int", "bool", "error", "byte",
                ],
                capitalizedTypes: true)
        case .python:
            return Rules(
                lineComments: ["#"], tripleQuotes: ["\"\"\"", "'''"],
                keywords: [
                    "def", "class", "return", "if", "elif", "else", "for", "while", "import", "from", "as", "with", "try",
                    "except", "finally", "raise", "pass", "None", "True", "False", "lambda", "yield", "in", "is", "not", "and",
                    "or", "async", "await", "self", "global", "nonlocal", "break", "continue",
                ],
                capitalizedTypes: true, marks: ["@"])
        case .shell:
            return Rules(
                lineComments: ["#"],
                keywords: [
                    "if", "then", "else", "elif", "fi", "for", "do", "done", "while", "until", "case", "esac", "function",
                    "return", "export", "local", "in", "echo", "set", "exit", "readonly", "source", "FROM", "RUN", "COPY",
                    "ENV", "WORKDIR", "ENTRYPOINT", "CMD", "ARG",
                ],
                marks: ["$"])
        case .json:
            return Rules(quotes: ["\""], keywords: ["true", "false", "null"])
        case .yaml:
            return Rules(
                lineComments: ["#"], keywords: ["true", "false", "null", "yes", "no", "on", "off"], yamlKeys: true)
        case .markup:
            return Rules(blockComment: (open: "<!--", close: "-->"), markupTags: true)
        case .css:
            return Rules(blockComment: cLike, keywords: ["important", "inherit", "none", "auto"], marks: ["$", "@"])
        case .plain:
            return Rules()
        }
    }
}
