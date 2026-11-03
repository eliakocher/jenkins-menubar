import Foundation

/// Finds out whether a comment mentions someone by `@username`, for the mention accent in the comment threads
/// (Task 7.03). A pure rule over the Markdown as written.
public enum Mentions {
    /// Returns whether a comment's Markdown mentions a user.
    ///
    /// - `@name` counts in any case, at the start of the text or after a space, a bracket, a quote or other
    ///   punctuation.
    /// - Not inside code: fenced blocks (``` and ~~~) and inline code spans are ignored.
    /// - Not part of an email address (`sam@name.example`), a link (`…/@name`) or a longer name (`@name2`, `@name.lee`,
    ///   `@name-ops`), and not a group (`@name/team`). A full stop after the name ends the sentence: `@name.` counts.
    ///
    /// - Parameters:
    ///   - username: the user's GitLab username, with or without the `@`
    ///   - markdown: the comment's text
    /// - Returns: whether the text mentions the user
    public static func contains(_ username: String, in markdown: String) -> Bool {
        let name = Array(username.drop { $0 == "@" }.lowercased())
        guard !name.isEmpty, markdown.contains("@") else {
            return false
        }
        let text = Array(withoutCode(markdown).lowercased())
        var index = 0
        while index < text.count {
            let end = index + 1 + name.count
            if text[index] == "@", end <= text.count, Array(text[(index + 1)..<end]) == name,
                startsAMention(text, at: index), endsAMention(text, at: end)
            {
                return true
            }
            index += 1
        }
        return false
    }

    /// whether the character before the `@` lets it start a mention
    private static func startsAMention(_ text: [Character], at index: Int) -> Bool {
        guard index > 0 else {
            return true
        }
        let before = text[index - 1]
        // A word, an email's local part, a link's path or another mention in front: not a mention.
        return !(isNameCharacter(before) || before == "/" || before == "@" || before == "+")
    }

    /// whether the character after the name ends it: a longer name, a group or the rest of a dotted name goes on
    private static func endsAMention(_ text: [Character], at end: Int) -> Bool {
        guard end < text.count else {
            return true
        }
        let after = text[end]
        if after == "." {
            // "@sam." closes a sentence; "@sam.lee" is someone else.
            return end + 1 >= text.count || !isNameCharacter(text[end + 1]) || text[end + 1] == "."
        }
        return !(isNameCharacter(after) || after == "/" || after == "@")
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character == "_" || character == "-" || character.isASCII && (character.isLetter || character.isNumber)
    }

    /// Returns the text without its fenced code blocks and inline code spans.
    static func withoutCode(_ markdown: String) -> String {
        var kept: [String] = []
        var fence: Character?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if let open = fence {
                // A fence closes with a line of the same mark.
                if trimmed.first == open, trimmed.prefix(3).allSatisfy({ $0 == open }), trimmed.count >= 3 {
                    fence = nil
                }
                continue
            }
            if let mark = trimmed.first, mark == "`" || mark == "~", trimmed.prefix(3).allSatisfy({ $0 == mark }),
                trimmed.count >= 3
            {
                fence = mark
                continue
            }
            kept.append(withoutCodeSpans(String(line)))
        }
        return kept.joined(separator: "\n")
    }

    /// Takes out the spans between two backtick runs of the same length. A run without its partner is plain text.
    private static func withoutCodeSpans(_ line: String) -> String {
        let characters = Array(line)
        var result = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "`" else {
                result.append(characters[index])
                index += 1
                continue
            }
            var run = 0
            while index + run < characters.count, characters[index + run] == "`" {
                run += 1
            }
            if let close = closing(run: run, in: characters, from: index + run) {
                // The span, and a space so that the words around it don't join.
                result.append(" ")
                index = close + run
            } else {
                result.append(String(repeating: "`", count: run))
                index += run
            }
        }
        return result
    }

    /// the index where a run of exactly `run` backticks starts, from `start` on
    private static func closing(run: Int, in characters: [Character], from start: Int) -> Int? {
        var index = start
        while index < characters.count {
            guard characters[index] == "`" else {
                index += 1
                continue
            }
            var length = 0
            while index + length < characters.count, characters[index + length] == "`" {
                length += 1
            }
            if length == run {
                return index
            }
            index += length
        }
        return nil
    }
}

extension ThreadNote {
    /// Returns whether the comment mentions a user (see ``Mentions/contains(_:in:)``).
    ///
    /// - Parameter username: the user's GitLab username; `nil` before it is known, which mentions nobody
    public func mentions(_ username: String?) -> Bool {
        username.map { Mentions.contains($0, in: body) } ?? false
    }
}

extension CommentThread {
    /// whether the first comment mentions a user
    public func firstMentions(_ username: String?) -> Bool {
        first.mentions(username)
    }

    /// whether the first comment or a reply mentions a user: the thread opens unfolded
    public func mentions(_ username: String?) -> Bool {
        first.mentions(username) || replies.contains { $0.mentions(username) }
    }
}
