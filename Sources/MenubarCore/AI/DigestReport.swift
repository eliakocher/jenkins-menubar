import Foundation

// MARK: - Claude's answer, read leniently (AI-04)

/// Claude's answer to the daily digest, read leniently: the JSON of ``ClaudePrompt/digestSchema`` from the structured
/// answer, a code fence or the text around it; missing fields read as empty, unknown sections and kinds as unknown.
/// `nil` when the answer holds no such JSON: the digest then shows Claude's text as Markdown.
public struct DigestReply: Hashable, Sendable {
    /// One item as Claude names it.
    public struct Item: Hashable, Sendable {
        public var kind: String?
        public var ref: String?
        public var title: String?
        public var state: String?
        public var why: String?
        public var next: String?

        public init(
            kind: String? = nil, ref: String? = nil, title: String? = nil, state: String? = nil, why: String? = nil,
            next: String? = nil
        ) {
            self.kind = kind
            self.ref = ref
            self.title = title
            self.state = state
            self.why = why
            self.next = next
        }
    }

    /// One section as Claude names it; `nil` for a section the app doesn't know.
    public struct Section: Hashable, Sendable {
        public var id: DigestReport.SectionKind?
        public var items: [Item]

        public init(id: DigestReport.SectionKind?, items: [Item]) {
            self.id = id
            self.items = items
        }
    }

    public var headline: String?
    public var sections: [Section]

    public init(headline: String? = nil, sections: [Section] = []) {
        self.headline = headline
        self.sections = sections
    }

    /// Reads Claude's answer: the structured answer first, then the text, as it is, in a code fence, or between its
    /// first `{` and its last `}`.
    ///
    /// - Parameters:
    ///   - structured: the structured answer's JSON, when `claude` gave one
    ///   - text: the answer's text
    /// - Returns: the reply; `nil` when neither holds the digest's JSON
    public static func parse(structured: Data?, text: String?) -> DigestReply? {
        var candidates: [Data] = []
        if let structured {
            candidates.append(structured)
        }
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            candidates.append(Data(text.utf8))
            if let fenced = fencedJSON(in: text) {
                candidates.append(Data(fenced.utf8))
            }
            if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
                candidates.append(Data(text[open...close].utf8))
            }
        }
        for data in candidates {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let reply = reply(of: object) {
                return reply
            }
        }
        return nil
    }

    /// The JSON in the first code fence of a text.
    private static func fencedJSON(in text: String) -> String? {
        guard let start = text.range(of: "```") else { return nil }
        let rest = text[start.upperBound...]
        // The fence's language, like `json`, ends at the line's end.
        let body = rest.drop { $0 != "\n" && $0 != "{" }
        guard let end = body.range(of: "```") else { return nil }
        return String(body[..<end.lowerBound])
    }

    private static func reply(of object: [String: Any]) -> DigestReply? {
        let headline = string(object, "headline", "summary")
        var sections: [Section] = []
        if let list = object["sections"] as? [Any] {
            for case let section as [String: Any] in list {
                let id = string(section, "id", "section", "name", "title").flatMap(DigestReport.SectionKind.init(named:))
                sections.append(Section(id: id, items: items(section["items"])))
            }
        } else if let byName = object["sections"] as? [String: Any] {
            for (name, value) in byName.sorted(by: { $0.key < $1.key }) {
                sections.append(Section(id: DigestReport.SectionKind(named: name), items: items(value)))
            }
        } else if let list = object["items"] as? [Any] {
            // One list, each item naming its section.
            var grouped: [(DigestReport.SectionKind?, [Item])] = []
            for case let entry as [String: Any] in list {
                guard let item = item(entry) else { continue }
                let id = string(entry, "section").flatMap(DigestReport.SectionKind.init(named:))
                if let index = grouped.firstIndex(where: { $0.0 == id }) {
                    grouped[index].1.append(item)
                } else {
                    grouped.append((id, [item]))
                }
            }
            sections = grouped.map { Section(id: $0.0, items: $0.1) }
        } else {
            // The sections as keys of their own.
            for kind in DigestReport.SectionKind.allCases {
                if let value = object.first(where: { DigestReport.SectionKind(named: $0.key) == kind })?.value {
                    sections.append(Section(id: kind, items: items(value)))
                }
            }
        }
        guard headline != nil || !sections.isEmpty else { return nil }
        return DigestReply(headline: headline, sections: sections)
    }

    private static func items(_ value: Any?) -> [Item] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { ($0 as? [String: Any]).flatMap(item) }
    }

    private static func item(_ entry: [String: Any]) -> Item? {
        let item = Item(
            kind: string(entry, "kind", "type"), ref: string(entry, "ref", "reference", "id"), title: string(entry, "title"),
            state: string(entry, "state", "status"),
            why: string(entry, "why", "whyItMatters", "why_it_matters", "reason"),
            next: string(entry, "next", "nextAction", "next_action", "nextStep", "next_step", "action"))
        return item.ref == nil && item.title == nil && item.why == nil ? nil : item
    }

    /// The first of the keys that holds a text or a number, trimmed; `nil` when none holds a text that isn't empty.
    private static func string(_ object: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            let value: String? = switch object[key] {
            case let text as String: text
            case let number as NSNumber: number.stringValue
            default: nil
            }
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

// MARK: - The digest as the page shows it

/// The daily digest as the page shows it (AI-04): the app's own items in sections, with Claude's priorities and its
/// why and next-step lines, what changed since the last digest, and a one-line summary computed from the facts.
public struct DigestReport: Codable, Hashable, Sendable {
    /// The page's sections, in their order.
    public enum SectionKind: String, Codable, Hashable, Sendable, CaseIterable {
        case needsYou
        case myMergeRequests
        case reviews
        case builds
        case workItems
        case fyi

        public var title: String {
            switch self {
            case .needsYou: "Needs You Now"
            case .myMergeRequests: "My Merge Requests"
            case .reviews: "Reviews Waiting on Me"
            case .builds: "Builds"
            case .workItems: "Work Items and Slots"
            case .fyi: "FYI"
            }
        }

        /// the SF Symbol of the section's card
        public var symbol: String {
            switch self {
            case .needsYou: "bolt.fill"
            case .myMergeRequests: "arrow.triangle.pull"
            case .reviews: "eye"
            case .builds: "hammer"
            case .workItems: "checklist"
            case .fyi: "info.circle"
            }
        }

        /// Reads a section's name as Claude may write it: `needsYou`, `needs_you`, "Needs You Now", `fyi`.
        public init?(named name: String) {
            let key = name.lowercased().filter(\.isLetter)
            switch key {
            case "needsyou", "needsyounow", "now", "urgent", "today", "actnow", "priority", "priorities":
                self = .needsYou
            case "mymergerequests", "mymrs", "mergerequests", "mrs", "mine":
                self = .myMergeRequests
            case "reviews", "reviewswaitingonme", "reviewswaiting", "reviewrequested", "reviewsrequested", "toreview":
                self = .reviews
            case "builds", "redbuilds", "pipelines":
                self = .builds
            case "workitems", "workitemsandslots", "slots", "items", "issues":
                self = .workItems
            case "fyi", "other", "others", "notes", "later", "info":
                self = .fyi
            default:
                return nil
            }
        }

        /// the section an item goes to when Claude puts it nowhere special
        static func home(of kind: DigestItem.Kind) -> SectionKind {
            switch kind {
            case .mergeRequest: .myMergeRequests
            case .review: .reviews
            case .build: .builds
            case .workItem, .slot: .workItems
            case .note: .fyi
            }
        }
    }

    /// What changed about an item since the last digest.
    public enum Change: Codable, Hashable, Sendable {
        /// it wasn't in the last digest
        case new
        /// its state was another one, given
        case changed(from: String)
    }

    /// One row: the item, Claude's lines about it, and what changed.
    public struct Row: Codable, Hashable, Sendable, Identifiable {
        public var item: DigestItem
        /// why it matters today, from Claude; `nil` when Claude said nothing about it
        public var why: String?
        /// the next step, from Claude
        public var next: String?
        public var change: Change?

        public init(item: DigestItem, why: String? = nil, next: String? = nil, change: Change? = nil) {
            self.item = item
            self.why = why
            self.next = next
            self.change = change
        }

        public var id: String { item.ref }
    }

    public struct Section: Codable, Hashable, Sendable, Identifiable {
        public var kind: SectionKind
        public var rows: [Row]
        /// how many open work items the card doesn't list, for its "+N more in Work Items" row; 0 for any other section
        public var more: Int

        public init(kind: SectionKind, rows: [Row], more: Int = 0) {
            self.kind = kind
            self.rows = rows
            self.more = more
        }

        public var id: SectionKind { kind }
    }

    /// One part of the summary line, like "2 MRs ready to merge". A count part knows the items it counts, so the page
    /// can name them in a tooltip and scroll to them.
    public struct SummaryPart: Codable, Hashable, Sendable, Identifiable {
        public var text: String
        public var symbol: String
        public var color: MergeRequestStatus.Color
        /// the references of the items the part counts, in the order the page lists them; empty for a part about no item
        public var refs: [String]
        /// whether a click scrolls to the Needs You Now card, not to the first of the items
        public var opensNeedsYou: Bool

        public init(
            text: String, symbol: String, color: MergeRequestStatus.Color, refs: [String] = [], opensNeedsYou: Bool = false
        ) {
            self.text = text
            self.symbol = symbol
            self.color = color
            self.refs = refs
            self.opensNeedsYou = opensNeedsYou
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            text = try values.decode(String.self, forKey: .text)
            symbol = try values.decode(String.self, forKey: .symbol)
            color = try values.decode(MergeRequestStatus.Color.self, forKey: .color)
            refs = try values.decodeIfPresent([String].self, forKey: .refs) ?? []
            opensNeedsYou = try values.decodeIfPresent(Bool.self, forKey: .opensNeedsYou) ?? false
        }

        public var id: String { text }

        /// whether a click has somewhere to go
        public var isClickable: Bool { opensNeedsYou || !refs.isEmpty }
    }

    /// Claude's sentence about the day; `nil` when it gave none
    public var headline: String?
    public var summary: [SummaryPart]
    /// the sections with rows, in their order; empty ones are left out
    public var sections: [Section]
    public var changes: DigestChanges
    /// when the facts were gathered
    public var gatheredAt: Date

    public init(
        headline: String? = nil, summary: [SummaryPart] = [], sections: [Section] = [], changes: DigestChanges = DigestChanges(),
        gatheredAt: Date
    ) {
        self.headline = headline
        self.summary = summary
        self.sections = sections
        self.changes = changes
        self.gatheredAt = gatheredAt
    }

    /// the most notes of Claude's that show
    static let notesShown = 3

    /// Puts the app's items and Claude's answer together. Each item shows once: in Needs You Now or FYI when Claude put
    /// it there, else in the section of its kind, Claude's order first, then the facts'. When Claude gave no Needs You Now
    /// section, the app's own rules fill it. An item Claude names that the facts don't have is left out; a note about no
    /// item goes to FYI. Work Items and Slots lists the slots first, then only the work items that need me (see
    /// ``DigestFacts/focused(changes:)``), and says how many more there are.
    ///
    /// - Parameters:
    ///   - facts: the facts that were sent
    ///   - reply: Claude's answer
    ///   - changes: what changed since the last digest
    public init(facts all: DigestFacts, reply: DigestReply, changes: DigestChanges = DigestChanges()) {
        let facts = all.focused(changes: changes)
        var placed: [String: SectionKind] = [:]
        var order: [String: Int] = [:]
        var lines: [String: (why: String?, next: String?)] = [:]
        var notes: [Row] = []
        for section in reply.sections {
            for entry in section.items {
                if let item = Self.match(entry, in: facts.items) {
                    guard placed[item.ref] == nil else { continue }
                    let id = section.id ?? SectionKind.home(of: item.kind)
                    placed[item.ref] = id == .needsYou || id == .fyi ? id : SectionKind.home(of: item.kind)
                    order[item.ref] = order.count
                    lines[item.ref] = (entry.why, entry.next)
                } else if entry.ref == nil || entry.kind == DigestItem.Kind.note.rawValue, notes.count < Self.notesShown,
                    let text = entry.title ?? entry.why
                {
                    let note = DigestItem(
                        kind: .note, ref: "note:\(notes.count)", shortRef: "", title: text,
                        state: DigestState(text: entry.state ?? "Note", symbol: "sparkles", color: .neutral))
                    notes.append(Row(item: note, why: entry.title == nil ? nil : entry.why, next: entry.next))
                }
            }
        }
        let claudeChose = reply.sections.contains { $0.id == .needsYou }
        var rows: [SectionKind: [(key: Int, row: Row)]] = [:]
        for (index, item) in facts.items.enumerated() {
            let home = SectionKind.home(of: item.kind)
            let section = placed[item.ref] ?? (!claudeChose && item.needsYou ? .needsYou : home)
            let line = lines[item.ref]
            let row = Row(item: item, why: line?.why, next: line?.next, change: changes.change(of: item))
            rows[section, default: []].append((order[item.ref] ?? facts.items.count + index, row))
        }
        // The work items of mine that are listed anywhere, for the rest's count.
        let listedWorkItems = rows.values.joined().count { $0.row.item.kind == .workItem }
        let more = max(facts.openWorkItems - listedWorkItems, 0)
        let ordered = SectionKind.allCases.compactMap { kind -> Section? in
            var list = (rows[kind] ?? []).sorted { $0.key < $1.key }.map(\.row)
            if kind == .fyi {
                list += notes
            }
            if kind == .workItems {
                // The slot summary on top, then the items that need me.
                list = list.filter { $0.item.kind == .slot } + list.filter { $0.item.kind != .slot }
                return list.isEmpty && more == 0 ? nil : Section(kind: kind, rows: list, more: more)
            }
            return list.isEmpty ? nil : Section(kind: kind, rows: list)
        }
        let needsYouRows = (rows[.needsYou] ?? []).sorted { $0.key < $1.key }.map(\.row)
        let slotRows = (rows[.workItems] ?? []).map(\.row).filter { $0.item.kind == .slot }
        self.init(
            headline: reply.headline, summary: Self.summary(of: facts, rows: needsYouRows, slots: slotRows),
            sections: ordered, changes: changes, gatheredAt: facts.gatheredAt)
    }

    /// The fact an item of Claude's names: by its reference, else by its short reference when only one item has it,
    /// else by its title.
    static func match(_ entry: DigestReply.Item, in items: [DigestItem]) -> DigestItem? {
        if let ref = entry.ref?.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")), !ref.isEmpty {
            if let found = items.first(where: { $0.ref.caseInsensitiveCompare(ref) == .orderedSame }) {
                return found
            }
            let short = items.filter { $0.shortRef.caseInsensitiveCompare(ref) == .orderedSame }
            if short.count == 1 {
                return short[0]
            }
            let suffix = items.filter { $0.ref.lowercased().hasSuffix(ref.lowercased()) }
            if suffix.count == 1 {
                return suffix[0]
            }
        }
        if let title = entry.title {
            let named = items.filter { $0.title.caseInsensitiveCompare(title) == .orderedSame }
            if named.count == 1 {
                return named[0]
            }
        }
        return nil
    }

    /// The summary line's parts: what needs me, counted once. The count chips come from the rows of Needs You Now, one per
    /// kind of item in it ("3 reviews waiting", "1 red build"). The total ("5 things need you") shows only when that
    /// card holds more than one kind, so a card of three reviews says "3 reviews waiting" and no more; with nothing
    /// in it the line says so. The nearest slot date follows. Every count part names its items (``SummaryPart/refs``).
    ///
    /// - Parameters:
    ///   - facts: the facts the digest is from, for the nearest slot date
    ///   - rows: the rows of Needs You Now, in the page's order
    ///   - slots: the rows of the slots the page lists, for the date's click; empty when not known
    static func summary(of facts: DigestFacts, rows: [Row], slots: [Row] = []) -> [SummaryPart] {
        func plural(_ count: Int, _ one: String, _ many: String) -> String {
            "\(count) \(count == 1 ? one : many)"
        }
        let deadline = facts.deadline
        let deadlineRef = deadline.map { "slot:\($0.slot)" }
        var parts: [SummaryPart] = []
        let kinds = DigestItem.Kind.allCases.filter { kind in rows.contains { $0.item.kind == kind } }
        if rows.isEmpty {
            parts.append(SummaryPart(text: "nothing needs you now", symbol: "checkmark.seal.fill", color: .green))
        } else if kinds.count > 1 {
            parts.append(
                SummaryPart(
                    text: rows.count == 1 ? "1 thing needs you" : "\(rows.count) things need you", symbol: "bolt.fill",
                    color: .red, refs: rows.map(\.item.ref), opensNeedsYou: true))
        }
        for kind in kinds {
            let own = rows.filter { $0.item.kind == kind }
            let refs = own.map(\.item.ref)
            let count = own.count
            switch kind {
            case .mergeRequest:
                let ready = own.filter { $0.item.state.text == MergeRequestStatus.readyToMergeText }.count
                if ready == count {
                    parts.append(
                        SummaryPart(
                            text: plural(count, "MR ready to merge", "MRs ready to merge"), symbol: "arrow.triangle.merge",
                            color: .green, refs: refs))
                } else {
                    parts.append(
                        SummaryPart(
                            text: plural(count, "MR needs you", "MRs need you"), symbol: "arrow.triangle.pull",
                            color: ready == 0 ? .red : .orange, refs: refs))
                }
            case .review:
                parts.append(SummaryPart(text: plural(count, "review waiting", "reviews waiting"), symbol: "eye.fill", color: .orange, refs: refs))
            case .build:
                parts.append(SummaryPart(text: plural(count, "red build", "red builds"), symbol: "xmark.octagon.fill", color: .red, refs: refs))
            case .workItem:
                parts.append(SummaryPart(text: plural(count, "work item needs you", "work items need you"), symbol: "checklist", color: .orange, refs: refs))
            case .slot:
                // The nearest slot date says it, when there is one.
                if deadline == nil {
                    parts.append(SummaryPart(text: plural(count, "slot needs you", "slots need you"), symbol: "calendar", color: .orange, refs: refs))
                }
            case .note:
                break
            }
        }
        if let deadline {
            let listed = slots.filter { $0.item.ref == deadlineRef }.map(\.item.ref)
            parts.append(
                SummaryPart(
                    text: deadline.text.prefix(1).lowercased() + deadline.text.dropFirst(),
                    symbol: deadline.text.hasPrefix("Code freeze") ? "snowflake" : "calendar",
                    color: deadline.isClose ? .orange : .blue, refs: listed))
        }
        return parts
    }

    /// The tooltip of a summary part: the items it counts by their short references ("!12484, !12462, !12477"), and what
    /// a click does; empty for a part that counts nothing.
    ///
    /// - Parameter part: a part of ``summary``
    public func help(of part: SummaryPart) -> String {
        guard part.isClickable else {
            return ""
        }
        let shortRefs = Dictionary(rows.map { ($0.item.ref, $0.item.shortRef) }, uniquingKeysWith: { first, _ in first })
        let names = part.refs.compactMap { shortRefs[$0] }.filter { !$0.isEmpty }
        let shown = names.prefix(Self.namesShown).joined(separator: ", ")
        let list = names.count > Self.namesShown ? "\(shown) and \(names.count - Self.namesShown) more" : shown
        let action = part.opensNeedsYou ? "Click to show Needs You Now." : "Click to show \(names.count == 1 ? "it" : "them")."
        return list.isEmpty ? action : "\(list). \(action)"
    }

    /// the most items a summary part's tooltip names
    static let namesShown = 8

    /// "3 things need you, 2 MRs ready to merge, code freeze in 4 days"
    public var summaryLine: String {
        let line = summary.map(\.text).joined(separator: ", ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// the rows of every section
    public var rows: [Row] { sections.flatMap(\.rows) }

    /// the rows that are new or changed since the last digest
    public var changedRows: Int { rows.filter { $0.change != nil }.count }

    // MARK: Search

    /// Returns the digest with only the rows whose words hold every word of the search, and how many they are; the
    /// whole digest and no count without a search.
    ///
    /// - Parameter query: the search field's text
    public func matching(_ query: String) -> (report: DigestReport, matches: Int) {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            return (self, 0)
        }
        var found = self
        found.sections = sections.compactMap { section in
            let rows = section.rows.filter { row in
                let text = ([row.item.shortRef, row.item.title, row.item.state.text, row.why ?? "", row.next ?? "", row.item.slot ?? ""]
                    + row.item.details).joined(separator: " ").lowercased()
                return words.allSatisfy(text.contains)
            }
            return rows.isEmpty ? nil : Section(kind: section.kind, rows: rows)
        }
        return (found, found.rows.count)
    }

    // MARK: As text

    /// The digest as Markdown, for Copy as Markdown (a chat message) and for Claude's follow-ups: the summary, the
    /// headline, each section's rows with their links, state, why and next step, and what was cleared.
    public var markdown: String {
        var lines = ["**Daily Digest**", summaryLine]
        if let headline {
            lines += ["", "> \(headline)"]
        }
        for section in sections {
            lines += ["", "**\(section.kind.title)**"]
            for row in section.rows {
                lines.append("- " + Self.markdown(row))
            }
            if section.more > 0 {
                lines.append("- +\(section.more) more in Work Items")
            }
        }
        if !changes.cleared.isEmpty {
            lines += ["", "**Cleared Since the Last Digest**"]
            for entry in changes.cleared {
                let ref = entry.link.map { "[\(entry.shortRef)](\($0.absoluteString))" } ?? entry.shortRef
                lines.append("- \(ref) \(entry.title)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Returns one row as a line of Markdown: its linked reference, title, state, what changed, why and next step.
    public static func markdown(_ row: Row) -> String {
        let item = row.item
        guard item.kind != .note else {
            return [item.title, row.why, row.next.map { "Next: \($0)" }].compactMap { $0 }.joined(separator: " ")
        }
        let ref = item.link.map { "[\(item.shortRef)](\($0.absoluteString))" } ?? item.shortRef
        var text = "\(ref) \(item.title): _\(item.state.text)_"
        switch row.change {
        case .new: text += " (new)"
        case .changed(let from): text += " (was \(from))"
        case nil: break
        }
        if let why = row.why {
            text += ". \(why)"
        }
        if let next = row.next {
            text += " **Next:** \(next)"
        }
        return text
    }

    /// The morning banner's text: the summary line, then the first items that need me, with their next step.
    public var bannerText: String {
        var lines = [summaryLine]
        let urgent = sections.first { $0.kind == .needsYou }?.rows.prefix(3) ?? []
        for row in urgent {
            lines.append("• \(row.item.shortRef) \(row.item.title): \(row.next ?? row.item.state.text)")
        }
        return lines.joined(separator: "\n")
    }
}

extension MergeRequestStatus {
    /// the text of MR-02's "Ready to merge" badge
    static let readyToMergeText = "Ready to merge"
}
