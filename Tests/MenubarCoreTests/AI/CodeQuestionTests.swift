import Foundation
import Testing

@testable import MenubarCore

/// AI-07: asking Claude about a merge request's code. Every input is made up; nothing runs `claude` or reaches GitLab.
@Suite("Ask Claude about code")
struct CodeQuestionTests {
    // MARK: - Picking lines

    @Test("AI-07 a click picks a line, a shift-click extends the pick within its file, a second click unpicks")
    func picksLines() throws {
        let hunks = Self.hunks
        let first = DiffLineID(old: 10, new: 10)
        let added = DiffLineID(old: nil, new: 12)
        let later = DiffLineID(old: 41, new: 43)

        let one = try #require(DiffSelection.click(added, path: "a.swift", extending: false, in: nil))
        #expect(one.lines(in: hunks).map(\.text) == ["let total = price * 2"])
        #expect(one.span(in: hunks) == LineSpan(first: 12, last: 12))
        #expect(one.span(in: hunks)?.buttonTitle == "Line 12")
        // The same line again unpicks it.
        #expect(DiffSelection.click(added, path: "a.swift", extending: false, in: one) == nil)

        // Shift-click upwards, then across the hunks: the lines in the diff's order, the new numbers spanned.
        let up = try #require(DiffSelection.click(first, path: "a.swift", extending: true, in: one))
        #expect(up.anchor == added)
        #expect(up.lines(in: hunks).count == 4)
        #expect(up.span(in: hunks) == LineSpan(first: 10, last: 12))
        let across = try #require(DiffSelection.click(later, path: "a.swift", extending: true, in: up))
        #expect(across.lines(in: hunks).first?.newNumber == 12)
        #expect(across.lines(in: hunks).last?.newNumber == 43)
        #expect(across.span(in: hunks)?.title == "lines 12–43")

        // A click elsewhere starts anew; a shift-click in another file too.
        #expect(DiffSelection.click(later, path: "a.swift", extending: false, in: across) == DiffSelection(path: "a.swift", anchor: later, head: later))
        #expect(DiffSelection.click(first, path: "b.swift", extending: true, in: across) == DiffSelection(path: "b.swift", anchor: first, head: first))

        // Only removed lines: the old numbers. A line gone from the diff: nothing picked.
        let removed = DiffLineID(old: 11, new: nil)
        let old = try #require(DiffSelection.click(removed, path: "a.swift", extending: false, in: nil))
        #expect(old.span(in: hunks) == LineSpan(first: 11, last: 11, isOld: true))
        #expect(old.span(in: hunks)?.buttonTitle == "Removed Line 11")
        let gone = DiffSelection(path: "a.swift", anchor: DiffLineID(old: 900, new: nil), head: added)
        #expect(gone.lines(in: hunks).isEmpty)
        #expect(gone.span(in: hunks) == nil)
    }

    // MARK: - The facts

    @Test("AI-07 sends the merge request, the picked lines marked with the diff around them, and the question last")
    func linesFacts() throws {
        let selection = DiffSelection(path: "Sources/Cart.swift", anchor: DiffLineID(old: nil, new: 12), head: DiffLineID(old: 10, new: 10))
        let span = try #require(selection.span(in: Self.hunks))
        let facts = Self.facts(scope: .lines(selection, span))
        let prompt = ClaudePrompt.codeQuestion(facts, question: "  Is the discount applied twice?  ")
        let text = prompt.text

        #expect(prompt.useCase == .askAboutCode)
        #expect(prompt.schema == nil)
        #expect(prompt.readableFolder == nil)
        #expect(text.contains(#"group/project!42 "Add cart discount" by Jane Doe (jdoe)"#))
        #expect(text.contains("Branches: feature/discount into develop"))
        #expect(text.contains("Head commit: 1a2b3c4d"))
        #expect(text.contains("Discounts apply after tax."))
        #expect(text.contains("# Diff: lines 10–12 of Sources/Cart.swift"))
        // The picked lines are marked; the unpicked hunk around them isn't, and both numbers show.
        #expect(text.contains(">10 10   func total() -> Int {"))
        #expect(text.contains(">   12 + let total = price * 2"))
        #expect(text.contains(" 13 13   return total"))
        #expect(text.contains("@@ -10,4 +10,5 @@ struct Cart"))
        #expect(text.hasSuffix("# Question\nIs the discount applied twice?"))
        // The diff isn't the instructions: the command line keeps only the app's text.
        #expect(!prompt.instructions.contains("discount"))
    }

    @Test("AI-07 a file sends its whole diff, cut with the lines left out counted; the merge request every file, cut with the files left out named")
    func fileAndMergeRequestFacts() throws {
        let file = ClaudePrompt.codeQuestion(Self.facts(scope: .file("Sources/Cart.swift")), question: "Explain this").text
        #expect(file.contains("## Sources/Cart.swift (modified, +2 -1)"))
        #expect(file.contains("@@ -40,3 +42,3 @@"))
        #expect(!file.contains("cut"))

        // Many big files: the first ones whole, then the rest by name with their +/−, and generated files by name only.
        let line = String(repeating: "x", count: 1_000)
        var files = [Self.cart]
        files.append(.init(oldPath: "Package.resolved", newPath: "Package.resolved", kind: .modified, isGenerated: true,
                           content: .hunks([DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, lines: [
                               DiffLine(kind: .added, text: "generated-pin", oldNumber: nil, newNumber: 1)])])))
        for index in 0..<120 {
            let lines = (1...10).map { DiffLine(kind: .added, text: line, oldNumber: nil, newNumber: $0) }
            files.append(.init(oldPath: "big/F\(index).swift", newPath: "big/F\(index).swift", kind: .added,
                               content: .hunks([DiffHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 10, lines: lines)])))
        }
        var facts = Self.facts(scope: .mergeRequest)
        facts.changes = MergeRequestChanges(files: files)
        let all = ClaudePrompt.codeQuestion(facts, question: "Review this").text
        #expect(all.contains("## Sources/Cart.swift"))
        #expect(all.contains("## Package.resolved (modified, generated, +1 -0)"))
        #expect(!all.contains("generated-pin"))
        #expect(all.contains("## big/F0.swift"))
        #expect(all.contains("# Cut for length: 113 more files (+1130 -0), not shown"))
        #expect(all.contains("- big/F7.swift (+10 -0)"))
        #expect(all.contains("- and 13 more"))
        #expect(all.count < CodeQuestionFacts.diffCharacters + 10_000)

        // One file too big alone: its start, and the lines left out counted.
        var huge = Self.facts(scope: .file("big/F0.swift"))
        let lines = (1...200).map { DiffLine(kind: .added, text: line, oldNumber: nil, newNumber: $0) }
        huge.changes = MergeRequestChanges(files: [.init(oldPath: "big/F0.swift", newPath: "big/F0.swift", kind: .added,
            content: .hunks([DiffHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 200, lines: lines)]))])
        let cut = ClaudePrompt.codeQuestion(huge, question: "Explain").text
        #expect(cut.contains("(cut: 121 more lines of this file)"))
    }

    @Test("AI-07 the facts are redacted before they go, and no token reaches the command line")
    func redactsAndKeepsTokensOff() throws {
        var facts = Self.facts(scope: .file("Sources/Cart.swift"))
        facts.description = "Deploy with token glpat-made-up-secret-value-1234567890 please"
        facts.checkout = CheckoutAccess(path: "/Users/dev/src/project", name: "project", branch: "feature/discount", head: "1a2b3c4d")
        let prompt = ClaudePrompt.codeQuestion(facts, question: "Why gitlab-secret-value-123 here?")
            .redacted(by: SecretRedactor(knownSecrets: ["gitlab-secret-value-123"]))
        #expect(!prompt.text.contains("gitlab-secret-value-123"))
        #expect(!prompt.text.contains("glpat-made-up-secret-value-1234567890"))
        #expect(prompt.text.contains("Deploy with token"))

        let command = ClaudeEngine.command(claude: URL(filePath: "/opt/homebrew/bin/claude"), for: prompt, model: .opus)
        let line = command.arguments.joined(separator: " ")
        for fact in ["glpat", "secret", "Why", "Discounts", "price * 2", "Cart.swift"] {
            #expect(!line.contains(fact), "\(fact) is on the command line")
        }
    }

    // MARK: - The command line

    @Test("AI-07 Claude reads the branch's checkout only with Read, Grep and Glob, inside it, the path one argument; else no tools")
    func readOnlyCheckout() throws {
        let claude = URL(filePath: "/opt/homebrew/bin/claude")
        let folder = "/Users/dev/src/my project; rm -rf ~"
        var facts = Self.facts(scope: .mergeRequest)
        facts.checkout = CheckoutAccess(path: folder, name: "my project", branch: "feature/discount", head: "1a2b3c4d")
        let reading = ClaudePrompt.codeQuestion(facts, question: "Review this")
        #expect(reading.readableFolder == folder)
        #expect(reading.text.contains("Checked out: feature/discount at 1a2b3c4d, the merge request's head."))

        let command = ClaudeEngine.command(claude: claude, for: reading, model: .sonnet)
        #expect(command.executable.path(percentEncoded: false) == "/usr/bin/env")
        #expect(Array(command.arguments.prefix(3)) == ["-C", folder, "/opt/homebrew/bin/claude"])
        let arguments = Array(command.arguments.dropFirst(3))
        #expect(arguments == ClaudeEngine.arguments(for: reading, model: .sonnet))
        let tools = try #require(arguments.firstIndex(of: "--tools"))
        #expect(arguments[tools + 1] == "Read,Grep,Glob")
        #expect(arguments.contains("--restricted"))
        #expect(arguments.contains("--safe-mode"))
        let addDir = try #require(arguments.firstIndex(of: "--add-dir"))
        #expect(arguments[addDir + 1] == folder)
        // A flag follows the folder, so `--add-dir`'s list ends there.
        #expect(arguments[addDir + 2].hasPrefix("--"))
        for never in ["Bash", "Edit", "Write", "--dangerously-skip-permissions", "bypassPermissions", "--allowedTools"] {
            #expect(!arguments.contains { $0.contains(never) }, "\(never) is on the command line")
        }

        // A checkout on another commit says so.
        facts.checkout?.head = "9f9f9f9f"
        #expect(ClaudePrompt.codeQuestion(facts, question: "Review").text.contains("not the merge request's head 1a2b3c4d"))

        // No checkout, a checkout on another branch, a relative path, or a claude path env would misread: no tools.
        var others: [ClaudePrompt] = []
        facts.checkout = nil
        others.append(ClaudePrompt.codeQuestion(facts, question: "Review"))
        facts.checkout = CheckoutAccess(path: "/Users/dev/src/project", name: "project", branch: "develop")
        others.append(ClaudePrompt.codeQuestion(facts, question: "Review"))
        facts.checkout = CheckoutAccess(path: "src/project", name: "project", branch: "feature/discount")
        others.append(ClaudePrompt.codeQuestion(facts, question: "Review"))
        for prompt in others {
            #expect(prompt.readableFolder == nil)
            #expect(!prompt.text.contains("# Local checkout"))
            let plain = ClaudeEngine.command(claude: claude, for: prompt, model: .opus)
            #expect(plain.executable == claude)
            #expect(Array(plain.arguments.prefix(7)) == ["-p", "--output-format", "json", "--model", "claude-opus-5-5", "--tools", ""])
            #expect(!plain.arguments.contains("--add-dir"))
        }
        let odd = ClaudeEngine.command(claude: URL(filePath: "/opt/A=B/claude"), for: reading, model: .opus)
        #expect(odd.executable.path(percentEncoded: false) == "/opt/A=B/claude")
        #expect(!odd.arguments.contains("--add-dir"))
        #expect(odd.arguments[odd.arguments.firstIndex(of: "--tools")! + 1] == "")
    }

    @Test("AI-07 a follow-up about another scope brings that scope's diff before its question, and names the scope in the history")
    func followUpScope() {
        let first = ClaudePrompt.codeQuestion(Self.facts(scope: .mergeRequest), question: "Review this")
        let answer = AIAnswer(text: "Looks fine.", model: "m", prompt: first, answeredAt: Date())
        let earlier = ConversationTurn(
            question: "What about this file?", askedAt: Date(), status: .answered("It totals.", model: "m", at: Date()),
            scope: .file("Sources/Cart.swift"))

        let other = Self.facts(scope: .file("Sources/Cart.swift"))
        let prompt = ClaudePrompt.followUp(
            to: answer, history: [earlier], question: "And the rounding?", context: ClaudePrompt.followUpDiff(other))
        let text = prompt.text
        #expect(text.hasPrefix(first.text))
        #expect(text.contains("## Developer's question 1\nWhat about this file? (about Sources/Cart.swift)"))
        let diff = text.range(of: "# Diff: Sources/Cart.swift", options: .backwards)
        let question = text.range(of: "# The developer's new question")
        #expect(diff != nil && question != nil && diff!.lowerBound < question!.lowerBound)
        #expect(text.hasSuffix("# The developer's new question\nAnd the rounding?"))

        // Without more code the follow-up is as before.
        let plain = ClaudePrompt.followUp(to: answer, history: [], question: "And the rounding?")
        #expect(!plain.text.contains("More code for the new question"))
        // The checkout the first question had stays readable.
        #expect(plain.readableFolder == first.readableFolder)
    }

    // MARK: - Fixtures

    private static let hunks: [DiffHunk] = [
        DiffHunk(oldStart: 10, oldCount: 4, newStart: 10, newCount: 5, section: "struct Cart", lines: [
            DiffLine(kind: .context, text: "func total() -> Int {", oldNumber: 10, newNumber: 10),
            DiffLine(kind: .removed, text: "let total = price", oldNumber: 11, newNumber: nil),
            DiffLine(kind: .added, text: "let discount = 0", oldNumber: nil, newNumber: 11),
            DiffLine(kind: .added, text: "let total = price * 2", oldNumber: nil, newNumber: 12),
            DiffLine(kind: .context, text: "return total", oldNumber: 13, newNumber: 13),
        ]),
        DiffHunk(oldStart: 40, oldCount: 3, newStart: 42, newCount: 3, lines: [
            DiffLine(kind: .context, text: "}", oldNumber: 40, newNumber: 42),
            DiffLine(kind: .context, text: "", oldNumber: 41, newNumber: 43),
            DiffLine(kind: .context, text: "// end", oldNumber: 42, newNumber: 44),
        ]),
    ]

    private static let cart = MergeRequestChanges.FileChange(
        oldPath: "Sources/Cart.swift", newPath: "Sources/Cart.swift", kind: .modified, content: .hunks(hunks))

    private static func facts(scope: CodeScope) -> CodeQuestionFacts {
        CodeQuestionFacts(
            reference: "group/project!42", title: "Add cart discount", author: MergeRequest.Person(username: "jdoe", name: "Jane Doe"),
            sourceBranch: "feature/discount", targetBranch: "develop", headCommit: "1a2b3c4d",
            description: "Discounts apply after tax.", scope: scope, changes: MergeRequestChanges(files: [cart]))
    }
}
