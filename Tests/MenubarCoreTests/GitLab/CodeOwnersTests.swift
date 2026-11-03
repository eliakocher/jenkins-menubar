import Foundation
import Testing

@testable import MenubarCore

/// Reading a `CODEOWNERS` file and finding the owners of the changed paths, as GitLab's documentation says (MR-15).
@Suite("CodeOwners")
struct CodeOwnersTests {
    // MARK: - Patterns

    @Test("MR-15 a CODEOWNERS pattern matches paths like GitLab's documentation says", arguments: [
        // (pattern, path, matches)
        ("*.java", "Main.java", true),
        ("*.java", "core/src/Main.java", true),
        ("*.java", "core/src/Main.javascript", false),
        ("README.md", "docs/README.md", true),
        ("/README.md", "README.md", true),
        ("/README.md", "docs/README.md", false),
        ("/docs/", "docs/a.md", true),
        ("/docs/", "docs/deep/er/a.md", true),
        ("/docs/", "other/docs/a.md", false),
        ("docs/", "other/docs/a.md", true),
        ("/docs/*", "docs/a.md", true),
        ("/docs/*", "docs/deep/a.md", false),
        ("/docs/**/*.md", "docs/a.md", true),
        ("/docs/**/*.md", "docs/deep/er/a.md", true),
        ("/docs/**/*.md", "docs/a.txt", false),
        ("/docs/**", "docs/deep/a.md", true),
        ("*", "any/where/file.txt", true),
        ("src/**/*Test.java", "src/a/b/FooTest.java", true),
        ("src/**/*Test.java", "src/FooTest.java", true),
        ("src/**/*Test.java", "lib/FooTest.java", false),
        ("file?.txt", "file1.txt", true),
        ("file?.txt", "file12.txt", false),
        ("[ab]c.txt", "ac.txt", true),
        ("[ab]c.txt", "cc.txt", false),
        ("[!ab]c.txt", "cc.txt", true),
        ("*.{java,kt}", "A.kt", true),
        ("*.{java,kt}", "A.swift", false),
        ("/a\\ b/*.md", "a b/x.md", true),
        // dotfiles are files like the others
        (".gitlab/CODEOWNERS", ".gitlab/CODEOWNERS", true),
        ("*.yml", ".github/ci.yml", true),
    ])
    func patterns(pattern: String, path: String, matches: Bool) {
        #expect(Glob(pattern).matches("/" + path) == matches)
    }

    // MARK: - Reading

    @Test("MR-15 reads sections with their optional mark, approvals and default owners, and the owners of each kind")
    func readsSections() throws {
        let file = CodeOwnersFile(parsing: try FixtureFiles.string("GitLab/codeowners-sample.txt"))

        // The lines before the first header are the default section; the second [Docs] is the first one again.
        #expect(file.sections.map(\.name) == [nil, "core", "Docs"])
        let core = file.sections[1]
        #expect(core.defaultOwners == [.user("slee")] && !core.isOptional && core.approvalsRequired == 1)
        // A pattern without owners gets the section's.
        #expect(core.rules[0].owners == [.user("slee")])
        #expect(core.rules[1].owners == [.user("akim"), .group("group/security")])
        let docs = file.sections[2]
        #expect(docs.approvalsRequired == 2 && docs.defaultOwners == [.user("docs-team-lead")])
        #expect(docs.rules.map(\.pattern) == ["/docs/", "/docs/generated/", "README.md"])
        #expect(docs.rules[1].isExclusion)
        #expect(docs.rules[2].owners == [.user("jdoe")])
    }

    @Test("MR-15 an owner token is a user, a group, a role or an email; anything else is none", arguments: [
        ("@jdoe", CodeOwnersFile.Owner.user("jdoe") as CodeOwnersFile.Owner?),
        ("@group/sub", .group("group/sub")),
        ("@@maintainer", .role("maintainer")),
        ("jdoe@example.com", .email("jdoe@example.com")),
        ("jdoe", nil),
        ("@", nil),
    ])
    func owners(token: String, expected: CodeOwnersFile.Owner?) {
        #expect(CodeOwnersFile.Owner(token) == expected)
    }

    @Test("MR-15 a comment, an escaped # and a pattern in brackets are told from a header")
    func commentsAndBrackets() {
        let file = CodeOwnersFile(parsing: """
            # all of it
            \\#hash.txt @a # trailing comment
            [ab]*.java @b
            [Sec] @c
            x.txt
            """)

        #expect(file.sections.map(\.name) == [nil, "Sec"])
        #expect(file.sections[0].rules.map(\.pattern) == ["#hash.txt", "[ab]*.java"])
        #expect(file.sections[0].rules[0].owners == [.user("a")])
        #expect(file.sections[1].rules[0].owners == [.user("c")])
    }

    // MARK: - Matching

    @Test("MR-15 in a section the last matching pattern wins, and the sections are independent")
    func lastMatchWins() throws {
        let file = CodeOwnersFile(parsing: try FixtureFiles.string("GitLab/codeowners-sample.txt"))

        let matches = file.matches(for: [
            "core/src/Main.java", "core/src/MainTest.java", "core/security/Keys.java", "docs/index.md", "docs/generated/api.md",
            "README.md",
        ])

        func owners(_ section: String?, _ pattern: String) -> [String]? {
            matches.first { $0.section == section && $0.pattern == pattern }?.paths
        }
        // Default section: `*` owns every file.
        #expect(owners(nil, "*")?.count == 6)
        // core: *.java owns Main.java; the Test pattern is later, so it wins for the test; the security folder is
        // later than *.java but earlier than the Test line, and Keys.java isn't a test.
        #expect(owners("core", "*.java") == ["core/src/Main.java"])
        #expect(owners("core", "core/src/**/*Test.java") == ["core/src/MainTest.java"])
        #expect(owners("core", "/core/security/") == ["core/security/Keys.java"])
        // Docs: the exclusion takes generated files out; README.md is later than /docs/ and wins only for itself.
        #expect(owners("Docs", "/docs/") == ["docs/index.md"])
        #expect(owners("Docs", "README.md") == ["README.md"])
        #expect(matches.contains { $0.pattern == "/docs/generated/" } == false)
    }

    @Test("MR-15 a path nobody owns gives no match, and a pattern without owners owns nothing")
    func nobodyOwns() {
        let file = CodeOwnersFile(parsing: "*.java @a\n/data/\n")

        #expect(file.matches(for: ["notes.txt", "data/x.csv"]).isEmpty)
    }
}
