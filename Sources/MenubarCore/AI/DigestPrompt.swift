import Foundation

extension ClaudePrompt {
    /// the system prompt of the daily digest: Claude orders and explains, the app has the facts
    static let digestInstructions = """
        You prioritize a developer's day from the facts given: their merge requests, the reviews waiting on them, the \
        red builds, their work items and the slots (release dates) those are in. Each item starts with its reference \
        in brackets. Answer only from the facts; don't invent items, people or numbers.
        Put in section "needsYou" the few items (at most 5) the developer should act on today, the most urgent first: \
        a red build of their own, a merge request ready to merge or blocked by a failed pipeline, conflicts or \
        requested changes, a review that waits on them, a slot near its code freeze or past its release with open \
        items, a blocked or overdue item. Put the other items you have something to say about in their own section \
        ("myMergeRequests", "reviews", "builds", "workItems" for work items and slots), and what is only worth \
        knowing in "fyi". List an item at most once; leave out items with nothing to add, the app shows them anyway.
        For each item: "ref" exactly as in the brackets, its "kind", "title" and "state" as given, "why": why it \
        matters today in one short sentence, "next": the next action in a few words, starting with a verb. A remark \
        about no single item goes in "fyi" with kind "note" and an empty ref. "headline": the day in one sentence of \
        at most 20 words.
        """

    /// the answer's shape of the daily digest
    static let digestSchema = """
        {"type":"object","properties":{"headline":{"type":"string","description":"one sentence, at most 20 words"},\
        "sections":{"type":"array","items":{"type":"object","properties":{\
        "id":{"type":"string","enum":["needsYou","myMergeRequests","reviews","builds","workItems","fyi"]},\
        "items":{"type":"array","items":{"type":"object","properties":{\
        "kind":{"type":"string","enum":["mergeRequest","review","build","workItem","slot","note"]},\
        "ref":{"type":"string","description":"the reference in brackets, exactly as given; empty for a note"},\
        "title":{"type":"string"},"state":{"type":"string"},\
        "why":{"type":"string","description":"why it matters today, one short sentence"},\
        "next":{"type":"string","description":"the next action, a few words, starting with a verb"}},\
        "required":["kind","ref","title","state","why","next"]}}},"required":["id","items"]}}},\
        "required":["headline","sections"]}
        """

    /// Returns the prompt of the daily digest (AI-04): today's date, then each part of the facts with its items, each
    /// item with its reference in brackets, which the answer names again. Of the work items it lists only those that
    /// need the developer (``DigestFacts/focused(changes:)``) and says how many there are in all, so the summary stays
    /// true and the prompt short.
    ///
    /// - Parameters:
    ///   - all: the facts from the app's stores
    ///   - changes: what changed since the last digest, which decides the work items that are listed
    /// - Returns: the prompt, not redacted yet
    public static func digest(_ all: DigestFacts, changes: DigestChanges = DigestChanges()) -> ClaudePrompt {
        let facts = all.focused(changes: changes)
        func line(_ item: DigestItem) -> String {
            var text = "- [\(item.ref)] \(item.shortRef) \"\(item.title)\": \(item.state.text)"
            if !item.details.isEmpty {
                text += "; " + item.details.joined(separator: "; ")
            }
            return text
        }
        func part(_ title: String, _ kind: DigestItem.Kind, total: Int? = nil) -> String {
            let items = facts.items(kind)
            var heading = "# \(title) (\(items.count))"
            if let total, total > items.count {
                heading = "# \(title) (\(total), \(items.count) listed: the ones that need me; the rest is not worth a line)"
            }
            return heading + "\n" + (items.isEmpty ? "- none" : items.map(line).joined(separator: "\n"))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE yyyy-MM-dd"
        let day = formatter.string(from: facts.gatheredAt)
        var parts = [
            "Write my daily digest from these facts. Today is \(day).",
            part("My merge requests", .mergeRequest),
            part("Reviews waiting on me", .review),
            part("Red builds", .build),
            part("My open work items", .workItem, total: facts.openWorkItems),
            part("Slots of my open work items", .slot),
        ]
        if let deadline = facts.deadline {
            parts.append("Nearest date: \(deadline.slot) \(deadline.text.prefix(1).lowercased() + deadline.text.dropFirst())")
        }
        return ClaudePrompt(
            useCase: .digest, instructions: digestInstructions, text: parts.joined(separator: "\n\n"), schema: digestSchema)
    }
}
