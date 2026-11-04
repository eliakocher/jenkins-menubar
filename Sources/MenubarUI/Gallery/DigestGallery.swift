#if DEBUG
import MenubarCore
import SwiftUI

/// The Digest section in the whole main window (AI-04), from made-up values: no model, no Claude.
struct DigestGalleryView: View {
    let fixtures: Fixtures
    var state: AIAnswerState
    var size = MainWindowGallerySize.standard
    var availability = ClaudeAvailability.found
    var isOffered = true
    /// the morning digest's time in minutes since midnight; `nil` while it is off
    var morningMinutes: Int?
    /// the search field's text
    var query = ""
    /// whether the sidebar's Digest row has its dot: a digest written and not seen yet
    var unread = false

    var body: some View {
        MainWindowGalleryView(
            model: MainWindowShellModel(
                fixtures.mainWindow().panel, section: .digest, digestSubtitle: DigestPage.subtitle(state: state),
                digestBusy: state.isBusy, digestUnread: unread),
            section: .digest, searchText: query, size: size
        ) {
            DigestContent(
                availability: availability, isOffered: isOffered, state: state, morningMinutes: morningMinutes,
                searchText: query, write: { _ in }, send: {}, dismiss: {}, openSettings: {})
        } detail: {
            EmptyView()
        }
    }

    /// the prompt of the digest, as sent
    static var prompt: ClaudePrompt {
        ClaudePrompt(
            useCase: .digest, instructions: "Prioritize a developer's day.",
            text: "# My merge requests (1)\n- [group/project!87] !87 \"Fix the login timeout for SSO users\": Ready to merge\n")
    }

    /// a digest as Claude wrote it before the cards: Markdown, a few lines per part; the page shows it when an answer
    /// isn't the digest's JSON
    static func markdown(_ f: Fixtures) -> AIAnswerState {
        .answered(
            AIAnswer(
                text: """
                    ## Today

                    - **!87 Fix the login timeout for SSO users** is green; one open thread from Sam waits for your answer.
                    - **2 reviews** are waiting for you: !91 (draft, wait for it) and !95 (small, 12 lines).

                    ## Red builds

                    - `release/2026.48` failed in *Integration Tests*: the same test failed in the last two runs, so it is
                      probably flaky, not your change.

                    ## By slot

                    - **2026.45** (released Monday): nothing open.
                    - **2026.48** (freezes today): #1234 is in progress, #1288 has no merge request yet.
                    """,
                model: ClaudeModel.opus.rawValue, prompt: prompt, answeredAt: f.minutesAgo(25)))
    }

    /// the whole digest: every section, Claude's lines, and what changed since yesterday's
    static func full(_ f: Fixtures) -> AIAnswerState {
        let facts = DigestGalleryFacts.facts(f)
        let reply = DigestReply(
            headline: "Merge !87 while it's green, then fix !92's tests before Friday's code freeze.",
            sections: [
                DigestReply.Section(id: .needsYou, items: [
                    DigestReply.Item(
                        ref: "group/project!87", why: "Approved by both reviewers and green: nothing left to wait for.",
                        next: "Merge it"),
                    DigestReply.Item(
                        ref: "build:main/MR-92", why: "Your change broke 2 cart tests; 2026.49 freezes in 3 days.",
                        next: "Fix CartServiceTest, then rebuild"),
                    DigestReply.Item(
                        ref: "group/project!95", why: "Sam asked yesterday and it's only 12 lines.", next: "Review it before lunch"),
                    DigestReply.Item(
                        ref: "slot:2026.49", why: "Two of your items in it have no merged MR yet.", next: "Check #1288 and #1301"),
                ]),
                DigestReply.Section(id: .myMergeRequests, items: [
                    DigestReply.Item(ref: "group/project!92", why: "Blocked by its failed pipeline.", next: "Fix the tests"),
                ]),
                DigestReply.Section(id: .workItems, items: [
                    DigestReply.Item(ref: "group/project#1288", why: "No merge request yet, and the freeze is close.", next: "Open a draft MR"),
                ]),
                DigestReply.Section(id: .fyi, items: [
                    DigestReply.Item(ref: "build:main/develop", why: "Someone else's: the same test was flaky twice this week."),
                    DigestReply.Item(kind: "note", title: "A lighter day after the merge: a good time for #1301."),
                ]),
            ])
        let changes = DigestChanges(
            previousAt: f.minutesAgo(24 * 60), new: ["build:main/MR-92", "group/project!95", "group/project#1305"],
            changed: ["group/project!87": "Missing 1 of 2 approvals", "group/project#1240": "No merge request"],
            cleared: [
                DigestSnapshot.Entry(
                    ref: "group/project!84", kind: "mergeRequest", shortRef: "!84", title: "Cache the slot labels",
                    state: "Ready to merge", link: URL(string: "https://gitlab.example.com/group/project/-/merge_requests/84")),
                DigestSnapshot.Entry(
                    ref: "group/project!80", kind: "review", shortRef: "!80", title: "Retry flaky uploads",
                    state: "Waiting on you", link: URL(string: "https://gitlab.example.com/group/project/-/merge_requests/80")),
            ])
        return answered(DigestReport(facts: facts, reply: reply, changes: changes), f)
    }

    /// a short digest, the first one: two things need me, no headline from Claude
    static func partial(_ f: Fixtures) -> AIAnswerState {
        var facts = DigestGalleryFacts.facts(f)
        facts.items = facts.items.filter { [.mergeRequest, .review].contains($0.kind) }
        facts.deadline = nil
        facts.openWorkItems = 0
        let reply = DigestReply(sections: [
            DigestReply.Section(id: .needsYou, items: [
                DigestReply.Item(ref: "group/project!87", why: "Approved and green.", next: "Merge it"),
                DigestReply.Item(ref: "group/project!95", next: "Review it"),
            ]),
        ])
        return answered(DigestReport(facts: facts, reply: reply), f)
    }

    /// the user's case: three reviews wait and nothing else needs me, so the summary says "3 reviews waiting" once, with
    /// no total, and the nearest date
    static func oneKind(_ f: Fixtures) -> AIAnswerState {
        var facts = DigestGalleryFacts.facts(f)
        let waiting = DigestState(text: "Waiting on you", symbol: "eye.circle.fill", color: .orange)
        let url = URL(string: "https://gitlab.example.com/group/project/-/merge_requests/97")
        facts.items = facts.items.filter { $0.kind == .review && $0.ref != "group/project!91" || $0.kind == .slot }
        facts.items.insert(
            DigestItem(
                kind: .review, ref: "group/project!97", shortRef: "!97", title: "Cache the slot labels per project",
                state: waiting, details: ["by Kim Park", "+88 −21", "updated 5 h ago"], link: url, needsYou: true), at: 0)
        facts.items.insert(
            DigestItem(
                kind: .review, ref: "group/project!99", shortRef: "!99", title: "Retry flaky uploads once",
                state: waiting, details: ["by Alex Roy", "+30 −4", "updated 1 day ago"],
                link: URL(string: "https://gitlab.example.com/group/project/-/merge_requests/99"), needsYou: true), at: 0)
        facts.openWorkItems = 0
        let reply = DigestReply(sections: [
            DigestReply.Section(id: .needsYou, items: [
                DigestReply.Item(ref: "group/project!95", next: "Review it before lunch"),
                DigestReply.Item(ref: "group/project!97", next: "Review it"),
                DigestReply.Item(ref: "group/project!99", next: "Review it"),
            ]),
        ])
        return answered(DigestReport(facts: facts, reply: reply), f)
    }

    /// reviews, a red build and a merge request ready to merge all need me: the total, then a chip per kind
    static func mixed(_ f: Fixtures) -> AIAnswerState {
        var facts = DigestGalleryFacts.facts(f)
        facts.items = facts.items.filter { [.mergeRequest, .review, .build, .slot].contains($0.kind) }
        facts.openWorkItems = 0
        let reply = DigestReply(
            headline: "Merge !87, fix !92's tests, then review !95.",
            sections: [
                DigestReply.Section(id: .needsYou, items: [
                    DigestReply.Item(ref: "group/project!87", why: "Approved by both reviewers and green.", next: "Merge it"),
                    DigestReply.Item(ref: "build:main/MR-92", why: "Your change broke 2 cart tests.", next: "Fix them, then rebuild"),
                    DigestReply.Item(ref: "group/project!95", why: "Sam asked yesterday.", next: "Review it before lunch"),
                ]),
            ])
        return answered(DigestReport(facts: facts, reply: reply), f)
    }

    private static func answered(_ report: DigestReport, _ f: Fixtures) -> AIAnswerState {
        .answered(
            AIAnswer(
                text: "{}", digest: report, model: ClaudeModel.opus.rawValue, prompt: prompt, answeredAt: f.minutesAgo(25)))
    }
}

/// The made-up items of the gallery's digests.
enum DigestGalleryFacts {
    static func facts(_ f: Fixtures) -> DigestFacts {
        let gitLab = "https://gitlab.example.com/group/project"
        func mr(_ iid: Int) -> URL { URL(string: "\(gitLab)/-/merge_requests/\(iid)")! }
        func issue(_ iid: Int) -> URL { URL(string: "\(gitLab)/-/issues/\(iid)")! }
        let ready = DigestState(text: "Ready to merge", symbol: "checkmark.circle.fill", color: .green)
        let failed = DigestState(text: "Pipeline failed", symbol: "xmark.circle.fill", color: .red)
        let waiting = DigestState(text: "Waiting on you", symbol: "eye.circle.fill", color: .orange)
        let draft = DigestState(text: "Draft", symbol: "pencil.circle.fill", color: .neutral)
        let open = DigestState(text: "Open", symbol: "circle", color: .neutral)
        let slotColor = "#1f75cb"
        let red = BuildID(job: "MR-92", number: 14, project: .main)
        // Open items that need nothing: the digest leaves them to Work Items.
        let backlog: [DigestItem] = (0..<8).map { index in
            DigestItem(
                kind: .workItem, ref: "group/project#\(1320 + index)", shortRef: "#\(1320 + index)",
                title: "Backlog item \(index + 1)", state: open, details: ["task", "slot 2026.51"], link: issue(1320 + index),
                slot: "2026.51", slotColor: slotColor)
        }
        return DigestFacts(
            items: [
                DigestItem(
                    kind: .mergeRequest, ref: "group/project!87", shortRef: "!87", title: "Fix the login timeout for SSO users",
                    state: ready, details: ["2 of 2 approved", "updated 2 h ago"], link: mr(87), needsYou: true),
                DigestItem(
                    kind: .mergeRequest, ref: "group/project!92", shortRef: "!92", title: "Apply the cart discount after tax",
                    state: failed, details: ["1 of 2 approved", "updated 40 min ago"], link: mr(92), needsYou: true),
                DigestItem(
                    kind: .mergeRequest, ref: "group/project!90", shortRef: "!90", title: "Try the new settings layout",
                    state: draft, details: ["updated 3 days ago"], link: mr(90)),
                DigestItem(
                    kind: .review, ref: "group/project!95", shortRef: "!95", title: "Round prices before the tax step",
                    state: waiting, details: ["by Sam Lee", "+9 −3", "updated 20 h ago"], link: mr(95), needsYou: true),
                DigestItem(
                    kind: .review, ref: "group/project!91", shortRef: "!91", title: "Spike: search by label",
                    state: draft, details: ["by Kim Park", "+412 −80", "updated 2 days ago"], link: mr(91)),
                DigestItem(
                    kind: .build, ref: "build:main/MR-92", shortRef: "!92 #14", title: "Apply the cart discount after tax",
                    state: DigestState(text: "Failed", symbol: "xmark.circle.fill", color: .red),
                    details: ["in Unit Tests", "2 of 1,204 tests failed", "mine", "finished 35 min ago"],
                    link: URL(string: "https://jenkins.example.com/job/project/job/MR-92/14/"), rebuild: red, needsYou: true),
                DigestItem(
                    kind: .build, ref: "build:main/develop", shortRef: "develop #512", title: "develop",
                    state: DigestState(text: "Unstable", symbol: "exclamationmark.triangle.fill", color: .orange),
                    details: ["in Integration Tests", "1 of 860 tests failed", "watched", "finished 2 h ago"],
                    link: URL(string: "https://jenkins.example.com/job/project/job/develop/512/")),
                DigestItem(
                    kind: .workItem, ref: "group/project#1288", shortRef: "#1288", title: "Discount codes for returning customers",
                    state: DigestState(text: "No merge request", symbol: "exclamationmark.triangle.fill", color: .orange),
                    details: ["issue", "slot 2026.49"], link: issue(1288), slot: "2026.49", slotColor: slotColor, needsYou: true),
                DigestItem(
                    kind: .workItem, ref: "group/project#1296", shortRef: "#1296", title: "Export the order history as CSV",
                    state: DigestState(text: "Red pipeline", symbol: "xmark.octagon.fill", color: .red),
                    details: ["issue", "slot 2026.49"], link: issue(1296), slot: "2026.49", slotColor: slotColor, needsYou: true),
                DigestItem(
                    kind: .workItem, ref: "group/project#1305", shortRef: "#1305", title: "Address form rejects long street names",
                    state: open, details: ["bug", "slot 2026.51"], link: issue(1305), slot: "2026.51", slotColor: slotColor),
                DigestItem(
                    kind: .workItem, ref: "group/project#1301", shortRef: "#1301", title: "Login page shows the wrong error",
                    state: DigestState(text: "Due tomorrow", symbol: "calendar", color: .orange),
                    details: ["bug", "slot 2026.49"], link: issue(1301), slot: "2026.49", slotColor: slotColor, needsYou: true),
                DigestItem(
                    kind: .workItem, ref: "group/project#1240", shortRef: "#1240", title: "Search speed on large projects",
                    state: open, details: ["task", "slot 2026.51"], link: issue(1240), slot: "2026.51", slotColor: slotColor),
            ] + backlog + [
                DigestItem(
                    kind: .slot, ref: "slot:2026.49", shortRef: "2026.49", title: "Slot 2026.49",
                    state: DigestState(text: "Code freeze in 3 days", symbol: "snowflake", color: .orange),
                    details: ["2 open items of mine", "code freeze 6 Nov 2026", "release 30 Nov 2026"], slot: "2026.49",
                    needsYou: true),
                DigestItem(
                    kind: .slot, ref: "slot:2026.51", shortRef: "2026.51", title: "Slot 2026.51",
                    state: DigestState(text: "Code freeze in 17 days", symbol: "calendar", color: .blue),
                    details: ["1 open item of mine", "code freeze 20 Nov 2026", "release 14 Dec 2026"], slot: "2026.51"),
            ],
            deadline: DigestFacts.Deadline(slot: "2026.49", text: "Code freeze in 3 days", days: 3, isClose: true),
            gatheredAt: f.minutesAgo(26), openWorkItems: 23)
    }
}

extension GalleryCatalog {
    /// The Digest section: the whole digest as cards, a short first one, a search, Claude's words as Markdown, none yet,
    /// while it is written, a failure, and the Claude features off; wide and narrow.
    static var digestEntries: [GalleryEntry] {
        let size = MainWindowGallerySize.standard
        let narrow = MainWindowGallerySize.minimum
        let tall = CGSize(width: size.width, height: 1500)
        return [
            GalleryEntry(screen: "digest", state: "full", size: tall) { f in
                DigestGalleryView(
                    fixtures: f, state: DigestGalleryView.full(f), size: tall, morningMinutes: 8 * 60 + 30, unread: true)
            },
            GalleryEntry(screen: "digest", state: "full-narrow", size: CGSize(width: narrow.width, height: 1900)) { f in
                DigestGalleryView(
                    fixtures: f, state: DigestGalleryView.full(f), size: CGSize(width: narrow.width, height: 1900),
                    unread: true)
            },
            GalleryEntry(screen: "digest", state: "partial", size: size) { f in
                DigestGalleryView(fixtures: f, state: DigestGalleryView.partial(f))
            },
            GalleryEntry(screen: "digest", state: "one-kind", size: size) { f in
                DigestGalleryView(fixtures: f, state: DigestGalleryView.oneKind(f), morningMinutes: 8 * 60)
            },
            GalleryEntry(screen: "digest", state: "mixed", size: size) { f in
                DigestGalleryView(fixtures: f, state: DigestGalleryView.mixed(f), morningMinutes: 8 * 60)
            },
            GalleryEntry(screen: "digest", state: "search", size: size) { f in
                DigestGalleryView(fixtures: f, state: DigestGalleryView.full(f), morningMinutes: 8 * 60 + 30, query: "review")
            },
            GalleryEntry(screen: "digest", state: "search-none", size: size) { f in
                DigestGalleryView(fixtures: f, state: DigestGalleryView.full(f), morningMinutes: 8 * 60 + 30, query: "deploy")
            },
            GalleryEntry(screen: "digest", state: "markdown", size: size) { f in
                DigestGalleryView(fixtures: f, state: DigestGalleryView.markdown(f), morningMinutes: 8 * 60 + 30)
            },
            GalleryEntry(screen: "digest", state: "markdown-search", size: size) { f in
                DigestGalleryView(fixtures: f, state: DigestGalleryView.markdown(f), morningMinutes: 8 * 60 + 30, query: "review")
            },
            GalleryEntry(screen: "digest", state: "empty", size: size) { f in
                DigestGalleryView(fixtures: f, state: .idle)
            },
            GalleryEntry(screen: "digest", state: "writing", size: size) { f in
                DigestGalleryView(fixtures: f, state: .running(DigestGalleryView.prompt))
            },
            GalleryEntry(screen: "digest", state: "failed", size: size) { f in
                DigestGalleryView(
                    fixtures: f, state: .failed("Claude didn't answer within 2 minutes.", DigestGalleryView.prompt))
            },
            GalleryEntry(screen: "digest", state: "claude-off", size: size) { f in
                DigestGalleryView(fixtures: f, state: .idle, availability: .found, isOffered: false)
            },
            GalleryEntry(screen: "digest", state: "writing-narrow", size: narrow) { f in
                DigestGalleryView(fixtures: f, state: .running(DigestGalleryView.prompt), size: narrow)
            },
        ]
    }
}
#endif
