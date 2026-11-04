import Foundation
import Testing

@testable import MenubarCore

/// AI-04: the daily digest's answer, its cards, its summary and what changed since the last one. Every value is made up.
@Suite("Digest")
struct DigestTests {
    // MARK: - Reading Claude's answer

    @Test(
        "AI-04 reads Claude's digest JSON: structured, as text, fenced or in words, with missing fields and unknown names",
        arguments: [
            // The structured answer.
            (nil, #"{"headline":"Merge !42.","sections":[{"id":"needsYou","items":[{"kind":"mergeRequest","ref":"group/project!42","title":"Add cart discount","state":"Ready to merge","why":"Approved and green.","next":"Merge it"}]}]}"#,
             "Merge !42.", ["needsYou"], "group/project!42", "Merge it"),
            // In a fence, after a sentence; a section name in words; a missing next step; snake case keys.
            ("Here is your digest:\n```json\n{\"headline\":\"Busy day\",\"sections\":[{\"id\":\"Needs You Now\",\"items\":[{\"ref\":\"!40\",\"why_it_matters\":\"Sam waits.\"}]}]}\n```\nGood luck!",
             nil, "Busy day", ["needsYou"], "!40", nil),
            // Between words, no fence; an unknown section and kind; a number as a ref.
            ("Sure. {\"sections\":[{\"id\":\"later\",\"items\":[{\"kind\":\"epic\",\"ref\":1234,\"title\":\"Cart\",\"nextAction\":\"Plan it\"}]},{\"id\":\"weekend\",\"items\":[]}]} Done.",
             nil, nil, ["fyi", "unknown"], "1234", "Plan it"),
            // One list of items, each naming its section.
            (#"{"headline":"h","items":[{"section":"builds","ref":"build:main/MR-42","next":"Fix the test"},{"section":"fyi","title":"Quiet week"}]}"#,
             nil, "h", ["builds", "fyi"], "build:main/MR-42", "Fix the test"),
            // The sections as keys.
            (#"{"needs_you":[{"ref":"group/project#1234","why":"Blocked."}],"fyi":[]}"#, nil, nil, ["needsYou", "fyi"],
             "group/project#1234", nil),
        ] as [(String?, String?, String?, [String], String, String?)])
    func readsTheReply(
        text: String?, structured: String?, headline: String?, sections: [String], firstRef: String, firstNext: String?
    ) throws {
        let reply = try #require(DigestReply.parse(structured: structured.map { Data($0.utf8) }, text: text))
        #expect(reply.headline == headline)
        #expect(reply.sections.map { $0.id?.rawValue ?? "unknown" } == sections)
        let first = try #require(reply.sections.first?.items.first)
        #expect(first.ref == firstRef)
        #expect(first.next == firstNext)
    }

    @Test(
        "AI-04 an answer in words, broken JSON or another shape is no digest: the page shows it as Markdown",
        arguments: [
            "## Today\n\n- **!42** is green; merge it.",
            "{\"sections\": [ {\"id\": \"needsYou\", \"items\": [",
            "{\"verdict\":\"real\",\"cause\":\"a test\"}",
            "",
        ])
    func refusesOtherAnswers(text: String) {
        #expect(DigestReply.parse(structured: nil, text: text) == nil)
    }

    // MARK: - The cards

    @Test("AI-04 the cards: Claude's Needs You Now and order, each item once, its why and next step, notes in FYI, nothing invented")
    func buildsTheCards() throws {
        let reply = DigestReply(
            headline: "Merge first, then review.",
            sections: [
                DigestReply.Section(id: .needsYou, items: [
                    DigestReply.Item(ref: "!40", why: "Sam waits since Friday.", next: "Review it"),
                    DigestReply.Item(ref: "group/project!42", why: "Approved and green.", next: "Merge it"),
                    // Invented: no such item.
                    DigestReply.Item(kind: "mergeRequest", ref: "group/project!99", title: "Ghost", why: "?"),
                ]),
                // Claude puts a review among the builds: it goes to its own section; a second mention is ignored.
                DigestReply.Section(id: .builds, items: [
                    DigestReply.Item(ref: "group/project#1240", why: "Freeze is close.", next: "Open an MR"),
                    DigestReply.Item(ref: "group/project!40", why: "again"),
                ]),
                DigestReply.Section(id: .fyi, items: [
                    DigestReply.Item(ref: "build:develop", why: "Someone else's."),
                    DigestReply.Item(kind: "note", ref: nil, title: "A quiet week otherwise."),
                ]),
            ])
        // #1240 is new since the last digest, so the digest lists it; a work item that is neither new nor in trouble stays out.
        let report = DigestReport(facts: Self.facts, reply: reply, changes: Self.newSearchSpeed)
        #expect(report.headline == "Merge first, then review.")
        #expect(report.sections.map(\.kind) == [.needsYou, .myMergeRequests, .workItems, .fyi])
        #expect(report.sections.map { $0.rows.map(\.item.shortRef) } == [
            ["!40", "!42"], ["!41"], ["2026.49", "#1240"], ["develop #3", ""],
        ])
        let review = try #require(report.rows.first)
        #expect(review.why == "Sam waits since Friday.")
        #expect(review.next == "Review it")
        #expect(report.rows.allSatisfy { $0.item.title != "Ghost" })
        #expect(report.rows.last?.item.kind == .note)
        #expect(report.rows.last?.item.title == "A quiet week otherwise.")
        // Items Claude said nothing about show without lines.
        #expect(report.rows.first { $0.item.shortRef == "!41" }?.why == nil)
    }

    @Test("AI-04 without Claude's Needs You Now the app's own rules fill it")
    func fallsBackToTheRules() {
        let report = DigestReport(facts: Self.facts, reply: DigestReply(headline: "h", sections: []))
        #expect(report.sections.first?.kind == .needsYou)
        #expect(report.sections.first?.rows.map(\.item.shortRef) == ["!42", "!40", "2026.49"])
    }

    @Test(
        "AI-04 the summary counts what is in Needs You Now once: a chip per kind, the total only when the card holds more than one kind, none when it is empty",
        arguments: [
            // One kind only: its chip, no total.
            (["group/project!40"], "1 review waiting, code freeze in 3 days"),
            (["group/project!42"], "1 MR ready to merge, code freeze in 3 days"),
            // Only needs that aren't reviews: still one kind, no total.
            (["build:develop"], "1 red build, code freeze in 3 days"),
            (["group/project#1240"], "1 work item needs you, code freeze in 3 days"),
            // Mixed kinds: the total, then a chip per kind in the page's order.
            (["group/project!40", "group/project!42"], "2 things need you, 1 MR ready to merge, 1 review waiting, code freeze in 3 days"),
            (["build:develop", "group/project!40", "group/project#1240"],
             "3 things need you, 1 review waiting, 1 red build, 1 work item needs you, code freeze in 3 days"),
            // Nothing in the card.
            ([], "Nothing needs you now, code freeze in 3 days"),
        ] as [([String], String)])
    func summarizes(needsYou: [String], line: String) {
        let items = needsYou.map { DigestReply.Item(ref: $0) }
        let reply = DigestReply(sections: [DigestReply.Section(id: .needsYou, items: items)])
        // #1240 is in trouble here, so the digest lists it.
        var facts = Self.facts
        facts.items[facts.items.firstIndex { $0.ref == "group/project#1240" }!].needsYou = true
        #expect(DigestReport(facts: facts, reply: reply).summaryLine == line)
    }

    @Test("AI-04 a summary chip names its items and knows where its click goes: the total to the card, a kind to its items")
    func summaryChipsKnowTheirItems() throws {
        let reply = DigestReply(sections: [
            DigestReply.Section(id: .needsYou, items: [
                DigestReply.Item(ref: "group/project!40"), DigestReply.Item(ref: "group/project!42"),
            ]),
        ])
        let report = DigestReport(facts: Self.facts, reply: reply)
        let total = try #require(report.summary.first)
        #expect(total.opensNeedsYou && total.refs == ["group/project!40", "group/project!42"])
        #expect(report.help(of: total) == "!40, !42. Click to show Needs You Now.")
        let review = try #require(report.summary.first { $0.text == "1 review waiting" })
        #expect(!review.opensNeedsYou && review.refs == ["group/project!40"])
        #expect(report.help(of: review) == "!40. Click to show it.")
        // The nearest date leads to the slot's row.
        let date = try #require(report.summary.last)
        #expect(date.refs == ["slot:2026.49"])
    }

    @Test(
        "AI-04 the search keeps the rows that hold every word of it, and counts them",
        arguments: [("", 6), ("review", 1), ("REVIEW it", 1), ("2026.49", 2), ("merge", 1), ("zzz", 0)])
    func searches(query: String, rows: Int) {
        let report = DigestReport(
            facts: Self.facts,
            reply: DigestReply(sections: [
                DigestReply.Section(id: .needsYou, items: [DigestReply.Item(ref: "!40", next: "Review it")]),
            ]),
            changes: Self.newSearchSpeed)
        let found = report.matching(query)
        #expect((query.isEmpty ? found.report.rows.count : found.matches) == rows)
    }

    // MARK: - Since the last digest

    @Test("AI-04 since the last digest: new, changed and cleared items; asking again keeps the marks; a first digest marks nothing")
    func comparesWithTheLastDigest() {
        var history = DigestHistory()
        // A first digest marks nothing.
        let first = history.record(Self.facts)
        #expect(first.isEmpty)
        #expect(first.previousAt == nil)

        // The next day: !42 merged (gone), !40's state changed, #1300 is new.
        var next = Self.facts
        next.gatheredAt = Self.now.addingTimeInterval(86_400)
        next.items.removeAll { $0.ref == "group/project!42" }
        next.items[next.items.firstIndex { $0.ref == "group/project!40" }!].state.text = "Draft"
        next.items.append(
            DigestItem(kind: .workItem, ref: "group/project#1300", shortRef: "#1300", title: "New bug", state: Self.open))
        let changes = history.record(next)
        #expect(changes.previousAt == Self.now)
        #expect(changes.new == ["group/project#1300"])
        #expect(changes.changed == ["group/project!40": "Waiting on you"])
        #expect(changes.cleared.map(\.shortRef) == ["!42"])
        let report = DigestReport(facts: next, reply: DigestReply(headline: "h"), changes: changes)
        #expect(report.rows.first { $0.item.ref == "group/project#1300" }?.change == .new)
        #expect(report.rows.first { $0.item.ref == "group/project!40" }?.change == .changed(from: "Waiting on you"))
        #expect(report.changedRows == 2)

        // Ask Again With sends the same facts: the same marks, not none.
        #expect(history.record(next) == changes)

        // Kept in the preferences.
        let defaults = TemporaryDefaults()
        history.save(to: defaults.defaults)
        #expect(DigestHistory.load(from: defaults.defaults) == history)
    }

    // MARK: - The work items the digest lists

    /// `count` open work items of mine, `#1000` and on: the first blocked, the next two flagged (a red pipeline, no merge
    /// request), then `plain` ones that need nothing
    private static func generatedItems(plain: Int) -> [DigestItem] {
        func item(_ number: Int, _ state: DigestState, needsYou: Bool) -> DigestItem {
            DigestItem(
                kind: .workItem, ref: "group/project#\(number)", shortRef: "#\(number)", title: "Item \(number)", state: state,
                needsYou: needsYou)
        }
        let blocked = DigestState(text: "Blocked", symbol: "hand.raised.fill", color: .red)
        let red = DigestState(text: "Red pipeline", symbol: "xmark.octagon.fill", color: .red)
        let none = DigestState(text: "No merge request", symbol: "exclamationmark.triangle.fill", color: .orange)
        return [item(1000, blocked, needsYou: true), item(1001, red, needsYou: true), item(1002, none, needsYou: true)]
            + (0..<plain).map { item(1003 + $0, open, needsYou: false) }
    }

    @Test("AI-04 the digest lists only the work items that need me, at most 5: the app's rules, then new, then changed")
    func focusesTheWorkItems() {
        let items = Self.generatedItems(plain: 20)
        let facts = DigestFacts(items: items + [Self.facts.items.last!], gatheredAt: Self.now, openWorkItems: 23)
        // Nothing to compare with: only what the rules say needs me.
        #expect(facts.focused(changes: DigestChanges()).items(.workItem).map(\.shortRef) == ["#1000", "#1001", "#1002"])
        // Two new and two changed items fill the rest, new ones first, then the cap.
        let changes = DigestChanges(
            previousAt: Self.now, new: ["group/project#1020", "group/project#1010"],
            changed: ["group/project#1005": "Open", "group/project#1004": "Open"])
        let focused = facts.focused(changes: changes)
        #expect(focused.items(.workItem).map(\.shortRef) == ["#1000", "#1001", "#1002", "#1010", "#1020"])
        #expect(DigestFacts.workItemsShown == 5)
        // The slot stays, and the whole count with it.
        #expect(focused.items(.slot).count == 1)
        #expect(focused.openWorkItemCount == 23)
        // Many items that need me still make five rows.
        let twice = Self.generatedItems(plain: 0) + Self.generatedItems(plain: 0).map {
            var copy = $0
            copy.ref += "b"
            return copy
        }
        let busy = DigestFacts(items: twice)
        #expect(busy.focused(changes: DigestChanges()).items(.workItem).count == 5)
    }

    @Test("AI-04 Work Items and Slots: the slot summary on top, at most 5 items, then \"+N more in Work Items\"")
    func countsWhatIsLeft() {
        let facts = DigestFacts(
            items: Self.generatedItems(plain: 20) + [Self.facts.items.last!], gatheredAt: Self.now, openWorkItems: 23)
        let changes = DigestChanges(previousAt: Self.now, new: ["group/project#1010", "group/project#1020", "group/project#1021"])
        // Claude chose Needs You Now (none here), so every item stays in the section of its kind.
        let chosen = DigestReply.Section(id: .needsYou, items: [])
        let report = DigestReport(facts: facts, reply: DigestReply(headline: "h", sections: [chosen]), changes: changes)
        let section = report.sections.first { $0.kind == .workItems }
        #expect(section?.rows.map(\.item.kind) == [.slot, .workItem, .workItem, .workItem, .workItem, .workItem])
        #expect(section?.rows.dropFirst().map(\.item.shortRef) == ["#1000", "#1001", "#1002", "#1010", "#1020"])
        #expect(section?.more == 18)
        #expect(report.markdown.contains("- +18 more in Work Items"))
        // Claude's Needs You Now takes an item out of the card, and the count of the rest follows.
        let reply = DigestReply(sections: [DigestReply.Section(id: .needsYou, items: [DigestReply.Item(ref: "group/project#1000")])])
        let moved = DigestReport(facts: facts, reply: reply, changes: changes)
        #expect(moved.sections.first { $0.kind == .workItems }?.more == 18)
        #expect(moved.sections.first { $0.kind == .needsYou }?.rows.map(\.item.shortRef) == ["#1000"])
        // Nothing needs me: the card is only the count, with no rows.
        let quiet = DigestFacts(items: Self.generatedItems(plain: 4).dropFirst(3).map { $0 }, gatheredAt: Self.now, openWorkItems: 4)
        let calm = DigestReport(facts: quiet, reply: DigestReply(headline: "h", sections: [chosen]))
        #expect(calm.sections.first { $0.kind == .workItems }?.rows.isEmpty == true)
        #expect(calm.sections.first { $0.kind == .workItems }?.more == 4)
        // Searching shows matching rows only, without the count.
        #expect(report.matching("1010").report.sections.first?.more == 0)
    }

    @Test("AI-04 Claude's prompt lists the work items that need me and still counts them all")
    func promptCountsWorkItems() {
        let facts = DigestFacts(items: Self.generatedItems(plain: 20), gatheredAt: Self.now, openWorkItems: 23)
        let prompt = ClaudePrompt.digest(facts)
        #expect(prompt.text.contains("# My open work items (23, 3 listed"))
        #expect(prompt.text.contains("[group/project#1001] #1001 \"Item 1001\": Red pipeline"))
        #expect(!prompt.text.contains("Item 1010"))
        // Few enough to list all: the plain count.
        let few = DigestFacts(items: Self.generatedItems(plain: 0), gatheredAt: Self.now, openWorkItems: 3)
        #expect(ClaudePrompt.digest(few).text.contains("# My open work items (3)\n"))
    }

    @Test("AI-04 the facts: Slots' red pipeline or missing merge request marks a work item, items of others stay out")
    func gathersFlaggedItems() throws {
        let calendar = Calendar(identifier: .gregorian)
        func item(_ number: Int, assignee: String?) -> WorkItem {
            WorkItem(
                reference: "group/project#\(number)", title: "Item \(number)",
                webURL: URL(string: "https://gitlab.example.com/group/project/-/issues/\(number)")!, state: .opened,
                updatedAt: Self.now, assignees: assignee.map { [MergeRequest.Person(username: $0, name: $0)] })
        }
        let facts = DigestFacts.gather(
            mergeRequests: nil, builds: [],
            workItems: [item(1, assignee: "jdoe"), item(2, assignee: "JDoe"), item(3, assignee: "slee"), item(4, assignee: nil)],
            me: "jdoe", slotFlags: ["group/project#1": .redPipeline, "group/project#2": .noMergeRequest],
            slotPrefix: "slot::", now: Self.now, calendar: calendar)
        let listed = facts.items(.workItem)
        // #3 is somebody else's; #4 has no assignee data, so it stays.
        #expect(listed.map(\.shortRef) == ["#1", "#2", "#4"])
        #expect(listed.map(\.state.text) == ["Red pipeline", "No merge request", "Open"])
        #expect(listed.map(\.needsYou) == [true, true, false])
        #expect(facts.openWorkItems == 3)
        // Without my name every item counts.
        #expect(DigestFacts.gather(
            mergeRequests: nil, builds: [], workItems: [item(3, assignee: "slee")], slotPrefix: "slot::", now: Self.now,
            calendar: calendar).openWorkItems == 1)
    }

    // MARK: - The store

    @Test("AI-04 a digest answered in JSON shows its cards and Markdown for Slack, one in words shows its text")
    @MainActor
    func storeReadsTheAnswer() async throws {
        let structured = #"{"headline":"Merge !42.","sections":[{"id":"needsYou","items":[{"kind":"mergeRequest","ref":"group/project!42","title":"t","state":"s","why":"Approved.","next":"Merge it"}]}]}"#
        let json = Data(#"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":\#(structured)}"#.utf8)
        let words = Data(###"{"type":"result","subtype":"success","is_error":false,"result":"## Today\n- merge !42"}"###.utf8)
        for (output, hasCards) in [(json, true), (words, false)] {
            let defaults = TemporaryDefaults()
            let fake = DigestClaude(answer: output)
            let store = AIStore(defaults: defaults.defaults, runner: fake, resolver: fake.resolver)
            store.update(AISettings(isEnabled: true, confirmedUseCases: [.digest]))
            store.digestFacts = { Self.facts }
            await store.writeDigest()
            guard case .answered(let answer) = store.state(of: .digest) else {
                Issue.record("expected an answer, got \(store.state(of: .digest))")
                continue
            }
            #expect((answer.digest != nil) == hasCards)
            if let digest = answer.digest {
                #expect(digest.sections.first?.rows.first?.next == "Merge it")
                #expect(answer.asText.hasPrefix("**Daily Digest**\n1 MR ready to merge, code freeze in 3 days"))
                #expect(digest.markdown.contains("- [!42](https://gitlab.example.com/group/project/-/merge_requests/42) Add cart discount: _Ready to merge_. Approved. **Next:** Merge it"))
                #expect(digest.bannerText.contains("• !42 Add cart discount: Merge it"))
            } else {
                #expect(answer.text == "## Today\n- merge !42")
            }
            // The snapshot for the next digest is kept either way.
            #expect(DigestHistory.load(from: defaults.defaults).last?.entries.count == Self.facts.items.count)
        }
    }

    private static let structuredAnswer = Data(
        #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"headline":"Merge !42.","sections":[{"id":"needsYou","items":[{"kind":"mergeRequest","ref":"group/project!42","title":"t","state":"s","why":"Approved.","next":"Merge it"}]}]}}"#.utf8)

    @MainActor
    private static func store(_ defaults: TemporaryDefaults, _ folder: TemporaryFolder, _ fake: DigestClaude) -> AIStore {
        let store = AIStore(
            defaults: defaults.defaults, digestFile: folder.file(AIStore.digestFileName), runner: fake, resolver: fake.resolver)
        store.update(AISettings(isEnabled: true, confirmedUseCases: [.digest]))
        return store
    }

    @Test("AI-04 the sidebar's dot: a written digest is unread until shown, a newer one is unread again, a relaunch keeps it")
    @MainActor
    func marksTheDigestUnread() async throws {
        let defaults = TemporaryDefaults()
        let folder = try TemporaryFolder()
        let fake = DigestClaude(answer: Self.structuredAnswer)
        let first = Self.store(defaults, folder, fake)
        #expect(!first.hasUnreadDigest)
        first.digestFacts = { Self.facts }
        await first.writeDigest()
        #expect(first.hasUnreadDigest)
        // A relaunch keeps the dot.
        #expect(Self.store(defaults, folder, fake).hasUnreadDigest)
        // Shown: it goes, also after a relaunch.
        first.markDigestSeen()
        #expect(!first.hasUnreadDigest)
        #expect(!Self.store(defaults, folder, fake).hasUnreadDigest)
        // Written again from the same facts (Ask Again With): nothing new to see.
        first.dismiss(.digest)
        await first.writeDigest()
        #expect(!first.hasUnreadDigest)
        // A new digest, from newer facts: unread again, and the relaunch sees it.
        first.dismiss(.digest)
        first.digestFacts = {
            var next = Self.facts
            next.gatheredAt = Self.now.addingTimeInterval(86_400)
            return next
        }
        await first.writeDigest()
        #expect(first.hasUnreadDigest)
        #expect(Self.store(defaults, folder, fake).hasUnreadDigest)
    }

    @Test("AI-04 the page survives a relaunch: the last digest comes back as it was, and Clear forgets it")
    @MainActor
    func keepsTheDigestForTheNextLaunch() async throws {
        let defaults = TemporaryDefaults()
        let folder = try TemporaryFolder()
        let fake = DigestClaude(answer: Self.structuredAnswer)
        let first = Self.store(defaults, folder, fake)
        first.digestFacts = { Self.facts }
        await first.writeDigest()
        guard case .answered(let written) = first.state(of: .digest) else {
            Issue.record("expected an answer")
            return
        }
        let second = Self.store(defaults, folder, fake)
        guard case .answered(let restored) = second.state(of: .digest) else {
            Issue.record("expected the digest after a relaunch, got \(second.state(of: .digest))")
            return
        }
        #expect(restored.digest == written.digest)
        #expect(restored.digest?.sections.first?.rows.first?.next == "Merge it")
        #expect(restored.answeredAt == written.answeredAt)
        #expect(restored.model == written.model)
        #expect(restored.prompt.text == written.prompt.text)
        #expect(second.hasUnreadDigest)
        // Clear forgets it.
        second.dismiss(.digest)
        #expect(!second.hasUnreadDigest)
        let third = Self.store(defaults, folder, fake)
        #expect(third.state(of: .digest) == .idle)
        #expect(!third.hasUnreadDigest)
    }

    @Test("AI-04 a corrupt or missing digest file shows no digest and no dot; history from before the dot is read, not unread")
    @MainActor
    func noDotWithoutAPage() async throws {
        let defaults = TemporaryDefaults()
        let folder = try TemporaryFolder()
        let fake = DigestClaude(answer: Self.structuredAnswer)
        // An update: the history of the digests before has no "seenAt", and no file was kept.
        var history = DigestHistory()
        _ = history.record(Self.facts)
        let old = try JSONEncoder().encode(history)
        let object = try #require(try JSONSerialization.jsonObject(with: old) as? [String: Any])
        #expect(object["seenAt"] == nil)
        defaults.defaults.set(old, forKey: DigestHistory.defaultsKey)
        #expect(history.hasUnread)
        let upgraded = Self.store(defaults, folder, fake)
        #expect(!upgraded.hasUnreadDigest)
        #expect(upgraded.state(of: .digest) == .idle)
        // A corrupt file, and a file of another shape.
        for text in ["not json {", #"{"version":2,"model":"m","answeredAt":0,"instructions":"","prompt":""}"#, "{}"] {
            try folder.write(text, to: AIStore.digestFileName)
            let store = Self.store(defaults, folder, fake)
            #expect(!store.hasUnreadDigest)
            #expect(store.state(of: .digest) == .idle)
        }
    }

    // MARK: - Made-up values

    static let now = Date(timeIntervalSince1970: 1_793_000_000)
    /// what a digest with #1240 as a new item says changed
    static let newSearchSpeed = DigestChanges(previousAt: now.addingTimeInterval(-86_400), new: ["group/project#1240"])
    static let open = DigestState(text: "Open", symbol: "circle", color: .neutral)

    /// !42 ready to merge, !41 a draft, !40 a review waiting, develop's watched red build, #1240 in 2026.49, which
    /// freezes in 3 days
    static let facts = DigestFacts(
        items: [
            DigestItem(
                kind: .mergeRequest, ref: "group/project!42", shortRef: "!42", title: "Add cart discount",
                state: DigestState(text: "Ready to merge", symbol: "checkmark.circle.fill", color: .green),
                link: URL(string: "https://gitlab.example.com/group/project/-/merge_requests/42"), needsYou: true),
            DigestItem(
                kind: .mergeRequest, ref: "group/project!41", shortRef: "!41", title: "Try new layout",
                state: DigestState(text: "Draft", symbol: "pencil.circle.fill", color: .neutral)),
            DigestItem(
                kind: .review, ref: "group/project!40", shortRef: "!40", title: "Fix rounding",
                state: DigestState(text: "Waiting on you", symbol: "eye.circle.fill", color: .orange), details: ["by Sam Lee"],
                needsYou: true),
            DigestItem(
                kind: .build, ref: "build:develop", shortRef: "develop #3", title: "develop",
                state: DigestState(text: "Unstable", symbol: "exclamationmark.triangle.fill", color: .orange),
                details: ["watched"]),
            DigestItem(
                kind: .workItem, ref: "group/project#1240", shortRef: "#1240", title: "Search speed", state: open,
                details: ["issue", "slot 2026.49"], slot: "2026.49"),
            DigestItem(
                kind: .slot, ref: "slot:2026.49", shortRef: "2026.49", title: "Slot 2026.49",
                state: DigestState(text: "Code freeze in 3 days", symbol: "snowflake", color: .orange), slot: "2026.49",
                needsYou: true),
        ],
        deadline: DigestFacts.Deadline(slot: "2026.49", text: "Code freeze in 3 days", days: 3, isClose: true),
        gatheredAt: now)
}

/// A `claude` that answers every run with the same output, found in `/opt/homebrew/bin`.
private actor DigestClaude: ProcessRunner {
    private let answer: Data

    init(answer: Data) {
        self.answer = answer
    }

    func run(_ executable: URL, arguments: [String], input: Data?) async throws -> ProcessOutput {
        executable.lastPathComponent == "zsh" ? ProcessOutput(status: 1) : ProcessOutput(status: 0, standardOutput: answer)
    }

    nonisolated var resolver: ProgramResolver {
        ProgramResolver(runner: self, home: URL(filePath: "/Users/nobody")) { $0 == "/opt/homebrew/bin/claude" }
    }
}
