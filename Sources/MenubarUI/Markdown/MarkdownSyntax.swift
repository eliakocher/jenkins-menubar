import SwiftUI

/// The colors of a code block (WIN-02): keywords, strings, comments, numbers, types and keys of the common languages,
/// and a diff's added and removed lines. A light tokenizer, not a parser: it colors what it recognizes and leaves the
/// rest in the text color. A block without a language, or one it doesn't know, stays plain. Kept per block by
/// ``MarkdownCache``.
enum MarkdownSyntax {
    enum Kind {
        case keyword, string, comment, number, type, attribute, added, removed, meta
    }

    /// What one family of languages looks like.
    struct Grammar {
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var quotes: Set<Character> = ["\"", "'"]
        var keywords: Set<String> = []
        /// whether keywords match without regard to case (SQL)
        var ignoresCase = false
        /// whether a capitalized word is a type (Swift, Java, Kotlin)
        var capitalizedTypes = false
        /// whether `@word` is an attribute or annotation
        var annotations = false
        /// whether `$NAME` and `${NAME}` are variables (shells)
        var variables = false
        /// whether a word or string followed by `:` is a key (JSON, YAML)
        var keys = false
        /// whether a word right after `<` or `</` is a tag (XML, HTML)
        var tags = false
        /// whether it is a diff, colored by line
        var isDiff = false
    }

    /// Returns the code in the colors of its language; plain for a language it doesn't know.
    static func highlight(_ code: String, language: String?) -> AttributedString {
        guard let grammar = grammar(for: language) else {
            return AttributedString(code)
        }
        var builder = Builder()
        if grammar.isDiff {
            for line in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.offset > 0 {
                    builder.append("\n", nil)
                }
                builder.append(String(line.element), diffKind(line.element))
            }
        } else {
            var tokenizer = Tokenizer(characters: Array(code), grammar: grammar)
            tokenizer.run(into: &builder)
        }
        return builder.finished
    }

    private static func diffKind(_ line: Substring) -> Kind? {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") || line.hasPrefix("diff ")
            || line.hasPrefix("index ")
        {
            return .meta
        }
        if line.hasPrefix("+") {
            return .added
        }
        if line.hasPrefix("-") {
            return .removed
        }
        return nil
    }

    // MARK: - Colors

    /// Xcode's default theme, in light and dark.
    static func color(_ kind: Kind) -> Color {
        switch kind {
        case .keyword: keyword
        case .string: string
        case .comment: comment
        case .number: number
        case .type: type
        case .attribute: attribute
        case .added: added
        case .removed: removed
        case .meta: meta
        }
    }

    private static let keyword = MarkdownColors.dynamic(light: 0x9B2393, dark: 0xFF7AB2)
    private static let string = MarkdownColors.dynamic(light: 0xC41A16, dark: 0xFF8170)
    private static let comment = MarkdownColors.dynamic(light: 0x6C7986, dark: 0x7F8C98)
    private static let number = MarkdownColors.dynamic(light: 0x1C00CF, dark: 0xD9C97C)
    private static let type = MarkdownColors.dynamic(light: 0x0B4F79, dark: 0x6BDFFF)
    private static let attribute = MarkdownColors.dynamic(light: 0x815F03, dark: 0xFFA14F)
    private static let added = MarkdownColors.dynamic(light: 0x1A7F37, dark: 0x6FDD8B)
    private static let removed = MarkdownColors.dynamic(light: 0xCF222E, dark: 0xFF8182)
    private static let meta = MarkdownColors.dynamic(light: 0x6639BA, dark: 0xC297FF)

    // MARK: - Languages

    static func grammar(for language: String?) -> Grammar? {
        guard let language = language?.lowercased().split(separator: " ").first.map(String.init) else {
            return nil
        }
        switch language {
        case "swift":
            return Grammar(
                lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], keywords: swiftKeywords,
                capitalizedTypes: true, annotations: true)
        case "java", "kotlin", "kt", "kts", "groovy", "gradle", "jenkinsfile", "scala", "dart", "cs", "csharp", "c#":
            return Grammar(
                lineComments: ["//"], blockComment: ("/*", "*/"), keywords: javaKeywords, capitalizedTypes: true,
                annotations: true)
        case "js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx":
            return Grammar(
                lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"], keywords: jsKeywords,
                capitalizedTypes: true, annotations: true)
        case "go", "golang", "rust", "rs", "c", "h", "cpp", "c++", "cc", "hpp", "objc", "objective-c", "m", "php":
            return Grammar(
                lineComments: ["//"], blockComment: ("/*", "*/"), keywords: cKeywords, capitalizedTypes: true)
        case "python", "py":
            return Grammar(lineComments: ["#"], keywords: pythonKeywords, capitalizedTypes: true, annotations: true)
        case "bash", "sh", "shell", "zsh", "console", "shellsession", "fish", "terminal":
            return Grammar(lineComments: ["#"], keywords: shellKeywords, variables: true)
        case "ruby", "rb":
            return Grammar(lineComments: ["#"], keywords: rubyKeywords, capitalizedTypes: true)
        case "yaml", "yml", "toml", "ini", "properties", "conf", "dockerfile", "docker", "makefile", "make":
            return Grammar(lineComments: ["#"], keywords: yamlKeywords, keys: true)
        case "json", "jsonc", "json5", "jsonl":
            return Grammar(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], keywords: ["true", "false", "null"], keys: true)
        case "sql", "postgres", "postgresql", "mysql", "plsql":
            return Grammar(lineComments: ["--"], blockComment: ("/*", "*/"), keywords: sqlKeywords, ignoresCase: true)
        case "xml", "html", "htm", "svg", "plist", "vue", "xhtml":
            return Grammar(blockComment: ("<!--", "-->"), tags: true)
        case "css", "scss", "less":
            return Grammar(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: ["important", "inherit", "none", "auto"])
        case "diff", "patch":
            return Grammar(isDiff: true)
        default:
            return nil
        }
    }

    private static let swiftKeywords: Set<String> = [
        "actor", "any", "as", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do",
        "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "guard", "if",
        "import", "in", "init", "inout", "internal", "is", "let", "mutating", "nil", "nonisolated", "open", "operator",
        "override", "private", "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "some", "static",
        "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "weak", "where",
        "while", "lazy", "get", "set", "willSet", "didSet", "consuming", "borrowing", "sending",
    ]
    private static let javaKeywords: Set<String> = [
        "abstract", "as", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "companion", "const",
        "continue", "data", "def", "default", "do", "double", "else", "enum", "extends", "false", "final", "finally",
        "float", "for", "fun", "if", "implements", "import", "in", "instanceof", "int", "interface", "internal", "is",
        "long", "namespace", "new", "null", "object", "override", "package", "private", "protected", "public", "record",
        "return", "sealed", "short", "static", "super", "switch", "synchronized", "this", "throw", "throws", "true",
        "try", "using", "val", "var", "void", "volatile", "when", "while", "yield", "string", "bool",
    ]
    private static let jsKeywords: Set<String> = [
        "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete",
        "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements",
        "import", "in", "instanceof", "interface", "let", "new", "null", "of", "private", "protected", "public",
        "readonly", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof",
        "undefined", "var", "void", "while", "yield", "string", "number", "boolean",
    ]
    private static let cKeywords: Set<String> = [
        "auto", "bool", "break", "case", "chan", "char", "const", "continue", "crate", "default", "defer", "do",
        "double", "else", "enum", "extern", "false", "float", "fn", "for", "func", "go", "goto", "if", "impl", "import",
        "int", "interface", "let", "long", "loop", "map", "match", "mod", "mut", "nil", "null", "package", "pub",
        "range", "return", "select", "self", "short", "signed", "sizeof", "static", "struct", "switch", "trait",
        "true", "type", "typedef", "union", "unsigned", "use", "var", "void", "while", "function", "echo", "new",
    ]
    private static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except",
        "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not",
        "or", "pass", "raise", "return", "self", "True", "try", "while", "with", "yield",
    ]
    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function",
        "return", "exit", "export", "local", "set", "unset", "source", "echo", "cd", "true", "false", "sudo",
    ]
    private static let rubyKeywords: Set<String> = [
        "begin", "class", "def", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "nil",
        "require", "rescue", "return", "self", "then", "true", "unless", "until", "when", "while", "yield",
    ]
    private static let yamlKeywords: Set<String> = [
        "true", "false", "null", "yes", "no", "on", "off", "FROM", "RUN", "CMD", "COPY", "ADD", "ENV", "ARG",
        "WORKDIR", "EXPOSE", "ENTRYPOINT", "USER", "VOLUME", "LABEL",
    ]
    private static let sqlKeywords: Set<String> = [
        "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create",
        "table", "alter", "drop", "index", "join", "left", "right", "inner", "outer", "on", "group", "by", "order",
        "having", "limit", "offset", "as", "distinct", "null", "is", "in", "like", "between", "case", "when", "then",
        "else", "end", "primary", "key", "foreign", "references", "default", "union", "all", "exists", "with",
    ]

    // MARK: - Tokenizer

    /// Pieces of text with their kinds, joined into one attributed text.
    struct Builder {
        private var text = AttributedString()
        private var pending = ""
        private var pendingKind: Kind?

        mutating func append(_ piece: String, _ kind: Kind?) {
            if kind != pendingKind {
                flush()
                pendingKind = kind
            }
            pending += piece
        }

        mutating func append(_ character: Character, _ kind: Kind?) {
            if kind != pendingKind {
                flush()
                pendingKind = kind
            }
            pending.append(character)
        }

        var finished: AttributedString {
            mutating get {
                flush()
                return text
            }
        }

        private mutating func flush() {
            guard !pending.isEmpty else {
                return
            }
            var piece = AttributedString(pending)
            if let pendingKind {
                piece.swiftUI.foregroundColor = MarkdownSyntax.color(pendingKind)
            }
            text += piece
            pending = ""
        }
    }

    private struct Tokenizer {
        let characters: [Character]
        let grammar: Grammar
        private var index = 0

        init(characters: [Character], grammar: Grammar) {
            self.characters = characters
            self.grammar = grammar
        }

        mutating func run(into builder: inout Builder) {
            let lowercasedKeywords = grammar.ignoresCase ? Set(grammar.keywords.map { $0.lowercased() }) : []
            while index < characters.count {
                let character = characters[index]
                if let block = grammar.blockComment, starts(with: block.open) {
                    let end = find(block.close, from: index + block.open.count).map { $0 + block.close.count } ?? characters.count
                    emit(to: end, .comment, &builder)
                } else if grammar.lineComments.contains(where: { starts(with: $0) }), isCommentStart(character) {
                    emit(to: lineEnd(from: index), .comment, &builder)
                } else if grammar.quotes.contains(character) {
                    let end = stringEnd(from: index)
                    let isKey = grammar.keys && nextNonSpace(from: end) == ":"
                    emit(to: end, isKey ? .attribute : .string, &builder)
                } else if character.isNumber, !isWordCharacter(before: index) {
                    var end = index + 1
                    while end < characters.count, characters[end].isHexDigit || "xX._".contains(characters[end]) {
                        end += 1
                    }
                    emit(to: end, .number, &builder)
                } else if grammar.variables, character == "$", index + 1 < characters.count,
                    characters[index + 1] == "{" || isWordStart(characters[index + 1])
                {
                    var end = index + 1
                    if characters[end] == "{" {
                        end = (find("}", from: end).map { $0 + 1 }) ?? characters.count
                    } else {
                        while end < characters.count, isWordCharacter(characters[end]) {
                            end += 1
                        }
                    }
                    emit(to: end, .type, &builder)
                } else if grammar.annotations, character == "@", index + 1 < characters.count,
                    isWordStart(characters[index + 1])
                {
                    emit(to: wordEnd(from: index + 1), .attribute, &builder)
                } else if isWordStart(character) {
                    let end = wordEnd(from: index)
                    let word = String(characters[index..<end])
                    let kind: Kind?
                    if grammar.tags, index > 0, characters[index - 1] == "<" || (characters[index - 1] == "/" && index > 1 && characters[index - 2] == "<") {
                        kind = .keyword
                    } else if grammar.tags, nextNonSpace(from: end) == "=" {
                        kind = .attribute
                    } else if grammar.keys, nextNonSpace(from: end) == ":", isLineKey(start: index) {
                        kind = .attribute
                    } else if grammar.ignoresCase ? lowercasedKeywords.contains(word.lowercased()) : grammar.keywords.contains(word) {
                        kind = .keyword
                    } else if grammar.capitalizedTypes, word.first?.isUppercase == true, word.contains(where: \.isLowercase) {
                        kind = .type
                    } else {
                        kind = nil
                    }
                    emit(to: end, kind, &builder)
                } else {
                    builder.append(character, nil)
                    index += 1
                }
            }
        }

        private mutating func emit(to end: Int, _ kind: Kind?, _ builder: inout Builder) {
            let end = max(end, index + 1)
            builder.append(String(characters[index..<min(end, characters.count)]), kind)
            index = min(end, characters.count)
        }

        private func starts(with prefix: String) -> Bool {
            var position = index
            for character in prefix {
                guard position < characters.count, characters[position] == character else {
                    return false
                }
                position += 1
            }
            return true
        }

        private func find(_ text: String, from start: Int) -> Int? {
            let pattern = Array(text)
            var position = start
            while position + pattern.count <= characters.count {
                if characters[position] == pattern[0],
                    pattern.indices.allSatisfy({ characters[position + $0] == pattern[$0] })
                {
                    return position
                }
                position += 1
            }
            return nil
        }

        private func lineEnd(from start: Int) -> Int {
            var position = start
            while position < characters.count, characters[position] != "\n" {
                position += 1
            }
            return position
        }

        /// The end of the string that starts at `start`, past its closing quote; a `'` or `"` string ends at the line's
        /// end too, a triple-quoted or backtick string can span lines.
        private func stringEnd(from start: Int) -> Int {
            let quote = characters[start]
            let isTriple = start + 2 < characters.count && characters[start + 1] == quote && characters[start + 2] == quote
            if isTriple {
                return find(String(repeating: quote, count: 3), from: start + 3).map { $0 + 3 } ?? characters.count
            }
            var position = start + 1
            while position < characters.count {
                let character = characters[position]
                if character == "\\" {
                    position += 2
                    continue
                }
                if character == quote {
                    return position + 1
                }
                if character == "\n", quote != "`" {
                    return position
                }
                position += 1
            }
            return characters.count
        }

        /// `#` starts a comment at a line's start or after a space (not in `$#` or `a#b`); `//` and `--` anywhere.
        private func isCommentStart(_ character: Character) -> Bool {
            guard character == "#" else {
                return true
            }
            return index == 0 || characters[index - 1].isWhitespace
        }

        /// whether the word at `start` is the first on its line, after spaces and a list's `- `
        private func isLineKey(start: Int) -> Bool {
            var position = start - 1
            while position >= 0, characters[position] == " " || characters[position] == "\t" || characters[position] == "-" {
                position -= 1
            }
            return position < 0 || characters[position] == "\n" || characters[position] == "{" || characters[position] == ","
        }

        private func nextNonSpace(from start: Int) -> Character? {
            var position = start
            while position < characters.count, characters[position] == " " {
                position += 1
            }
            return position < characters.count ? characters[position] : nil
        }

        private func wordEnd(from start: Int) -> Int {
            var position = start
            while position < characters.count, isWordCharacter(characters[position]) || (grammar.keys && characters[position] == "-") {
                position += 1
            }
            return position
        }

        private func isWordStart(_ character: Character) -> Bool {
            character.isLetter || character == "_"
        }

        private func isWordCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }

        private func isWordCharacter(before position: Int) -> Bool {
            position > 0 && (isWordCharacter(characters[position - 1]) || characters[position - 1] == ".")
        }
    }
}
