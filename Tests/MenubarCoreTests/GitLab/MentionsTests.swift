import Foundation
import Testing

@testable import MenubarCore

/// Which comments mention me, for the accent bar and the "@you" badge (Task 7.03).
@Suite("Mentions")
struct MentionsTests {
    @Test(
        "INBOX-13 a comment mentions me by @username, in any case, not inside code, an email address or a longer name",
        arguments: [
            // mentions
            ("@jdoe can you look?", true),
            ("Thanks @JDoe!", true),
            ("(cc @jdoe)", true),
            ("ping\n@jdoe", true),
            ("Done, @jdoe.", true),
            ("@jdoe, @sam", true),
            ("Not code: `x` then @jdoe", true),
            ("`unclosed @jdoe", true),
            // not inside code
            ("run `git blame @jdoe` first", false),
            ("```\n@jdoe\n```", false),
            ("~~~sh\nnotify @jdoe\n~~~", false),
            ("``a ` @jdoe``", false),
            // after a code block it counts again
            ("```\ncode\n```\n@jdoe look", true),
            // email addresses and links
            ("write to sam@jdoe.example", false),
            ("mail jdoe@jdoe.dev", false),
            ("https://gitlab.example.com/@jdoe/project", false),
            // partial and longer names
            ("@jdoe2 and @jd and @jdoes", false),
            ("@jdoe.lee asked", false),
            ("@jdoe-ops asked", false),
            ("@jdoe_bot asked", false),
            ("@jdoe/backend asked", false),
            ("@@jdoe", false),
            ("no mention, just jdoe", false),
            ("", false),
        ])
    func mentionsMe(markdown: String, expected: Bool) {
        #expect(Mentions.contains("jdoe", in: markdown) == expected)
    }

    @Test("INBOX-13 the username may come with its @, and nobody is mentioned before it is known")
    func usernameForms() {
        #expect(Mentions.contains("@jdoe", in: "hi @jdoe"))
        #expect(!Mentions.contains("", in: "hi @jdoe"))
        let note = ThreadNote(id: "n1", author: nil, body: "hi @jdoe")
        #expect(note.mentions("jdoe"))
        #expect(!note.mentions(nil))
    }

    @Test("INBOX-13 a reply that mentions me makes the thread one that mentions me")
    func threads() {
        let plain = ThreadNote(id: "n1", author: nil, body: "Looks fine")
        let reply = ThreadNote(id: "n2", author: nil, body: "@jdoe what do you think?")
        let thread = CommentThread(id: "t1", first: plain, replies: [reply])
        #expect(thread.mentions("jdoe"))
        #expect(!thread.firstMentions("jdoe"))
        #expect(!CommentThread(id: "t2", first: plain).mentions("jdoe"))
    }
}
