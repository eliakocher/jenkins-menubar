import Foundation
import MenubarCore

/// What the work item header's facts panel shows of the labels (WI-04): the scoped labels as facts, one per line, a name
/// and a value, and the rest of the labels behind one quiet line.
///
/// The labels Team names come first, in a fixed order and under fixed names: Slot, Due slot, Status, Type, Priority,
/// Squad, Size, Commitment. The other scoped labels follow in GitLab's order, one fact per name, named after the scope
/// ("release-train::…" is "Release train", "xFooBar::…" "Foo bar"), up to ``limit`` facts in all; a second scheme's
/// label with a fact's name and value says nothing new and is left out. Plain labels, and the scoped ones past the limit,
/// are the ``otherLabels``.
struct WorkItemFacts: Hashable, Sendable {
    /// One line of the panel: "Status  In progress".
    struct Fact: Hashable, Sendable, Identifiable {
        /// "Slot", "Status", "Release train"
        var name: String
        /// the labels it shows, usually one; a squad can have several
        var labels: [LabelPillModel]
        /// each label's value as it comes, without Team's prefix or the scope: "InProgress", "group:Alpha"
        var rawValues: [String]

        var id: String { name }

        /// "In progress", "2026.51", "Alpha, Bravo"
        var value: String {
            values.joined(separator: ", ")
        }

        /// each label's value as shown
        var values: [String] {
            rawValues.map(WorkItemFacts.valueText)
        }

        mutating func append(_ label: LabelPillModel, raw: String) {
            // The same value twice, from two schemes, is shown once.
            guard !values.contains(where: { $0.caseInsensitiveCompare(WorkItemFacts.valueText(raw)) == .orderedSame }) else {
                return
            }
            labels.append(label)
            rawValues.append(raw)
        }
    }

    var facts: [Fact]
    /// the labels no fact shows, in GitLab's order: the plain ones and the scoped ones past the limit
    var otherLabels: [LabelPillModel]

    /// the most facts the panel lists; the labels Team names always count
    static let limit = 12

    /// - Parameters:
    ///   - labels: the item's labels, in GitLab's order
    ///   - team: the Team values with the label prefixes
    init(labels: [LabelPillModel], team: TeamValues) {
        var left = labels
        var facts: [Fact] = []

        /// Takes the labels with the prefix out of `left`, with their values after the prefix; only the first one
        /// unless `all`.
        func take(prefix: String, all: Bool = false) -> (labels: [LabelPillModel], raw: [String]) {
            guard !prefix.isEmpty else { return ([], []) }
            var taken: [LabelPillModel] = []
            left.removeAll { label in
                guard all || taken.isEmpty, label.title.hasPrefix(prefix) else { return false }
                taken.append(label)
                return true
            }
            return (taken, taken.map { String($0.title.dropFirst(prefix.count)) })
        }

        let slot = take(prefix: team.slotPrefix)
        if !slot.labels.isEmpty {
            facts.append(Fact(name: "Slot", labels: slot.labels, rawValues: slot.raw))
        }
        if let duePrefix = team.dueSlotPrefix {
            let due = take(prefix: duePrefix)
            // The same week twice says nothing new.
            if !due.labels.isEmpty, due.raw.first != slot.raw.first {
                facts.append(Fact(name: "Due slot", labels: due.labels, rawValues: due.raw))
            }
        }
        for (name, prefix, all) in [
            ("Status", team.statusLabelPrefix, false), ("Type", team.typeLabelPrefix, false),
            ("Priority", team.priorityLabelPrefix, false), ("Squad", team.squadLabelPrefix, true),
            ("Size", team.sizeLabelPrefix, false),
        ] {
            let taken = take(prefix: prefix, all: all)
            if !taken.labels.isEmpty {
                facts.append(Fact(name: name, labels: taken.labels, rawValues: taken.raw))
            }
        }
        let committed = team.committedLabel.trimmingCharacters(in: .whitespaces)
        if !committed.isEmpty, let index = left.firstIndex(where: { $0.title == committed }) {
            let label = left.remove(at: index)
            // A plain committed label has no value of its own: the line says "Committed".
            facts.append(Fact(name: "Commitment", labels: [label], rawValues: [label.value ?? "Committed"]))
        }

        // The other scoped labels, a fact per name while there is room; one with a fact's name joins it.
        var others: [LabelPillModel] = []
        for label in left {
            guard let (name, raw) = Self.nameAndValue(of: label) else {
                others.append(label)
                continue
            }
            if let index = facts.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                // Another scheme's label for a fact shown: its value joins the line, or says nothing new.
                facts[index].append(label, raw: raw)
            } else if label.scope != nil, facts.count < Self.limit {
                facts.append(Fact(name: name, labels: [label], rawValues: [raw]))
            } else {
                others.append(label)
            }
        }
        self.facts = facts
        otherLabels = others
    }

    /// A label's fact name and value: a scoped label's scope and value, or a plain one's parts around its last `:`, such
    /// as `xGroup:Alpha`; `nil` for a label without either.
    private static func nameAndValue(of label: LabelPillModel) -> (name: String, raw: String)? {
        if let scope = label.scope, let value = label.value {
            return (scopeName(scope), value)
        }
        guard let colon = label.title.lastIndex(of: ":"), colon != label.title.startIndex,
            label.title.index(after: colon) != label.title.endIndex
        else {
            return nil
        }
        return (scopeName(String(label.title[..<colon])), String(label.title[label.title.index(after: colon)...]))
    }

    /// A scope as a fact's name, in sentence case: "release-train" is "Release train", "earlyAccess" "Early access",
    /// "xFooBarStatus" "Foo bar status" (a lone small letter before a capital is a scheme's mark, not a word), a nested
    /// "team::web" "Team › Web".
    static func scopeName(_ scope: String) -> String {
        let parts = scope.components(separatedBy: "::").map { part in
            let chars = Array(part)
            let unmarked = chars.count > 2 && chars[0].isLowercase && chars[1].isUppercase ? String(chars.dropFirst()) : part
            return words(of: unmarked).enumerated().map { index, word in
                // Acronyms keep their capitals: "QA", "UI".
                if word.count > 1, word == word.uppercased() { return word }
                let lower = word.lowercased()
                return index == 0 ? lower.prefix(1).uppercased() + lower.dropFirst() : lower
            }
            .joined(separator: " ")
        }
        let name = parts.filter { !$0.isEmpty }.joined(separator: " › ")
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// A label's value as a fact shows it: GitLab's words, in sentence case only where that can't be wrong. A CamelCase
    /// value is split, "InProgress" "In progress"; an all-lowercase one gets its capital, "high" "High"; anything else
    /// stays as it is ("2026.51", "iOS", "Q1"). A value with a `:` shows the part after the last one: "group:Alpha"
    /// is "Alpha".
    static func valueText(_ raw: String) -> String {
        // "group:Alpha" names the squad Alpha: the name is after the last `:`.
        let value = raw.lastIndex(of: ":").map { String(raw[raw.index(after: $0)...]) }.flatMap { $0.isEmpty ? nil : $0 } ?? raw
        let humps = camelHumps(value)
        if humps.count > 1 {
            return ([humps[0]] + humps.dropFirst().map { $0.lowercased() }).joined(separator: " ")
        }
        if value.first?.isLowercase == true, value == value.lowercased() {
            return value.prefix(1).uppercased() + value.dropFirst()
        }
        return value
    }

    /// The words of "release-train", "release_train", "earlyAccess": split at `-`, `_`, spaces and a capital after a
    /// small letter or a digit.
    private static func words(of text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character == "-" || character == "_" || character == " " {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                if character.isUppercase, let previous, previous.isLowercase || previous.isNumber, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The humps of a CamelCase word, "InProgress" → ["In", "Progress"]; empty unless every hump is a capital with small
    /// letters after it.
    private static func camelHumps(_ value: String) -> [String] {
        var humps: [String] = []
        for character in value {
            if character.isUppercase {
                humps.append(String(character))
            } else if character.isLowercase, !humps.isEmpty {
                humps[humps.count - 1].append(character)
            } else {
                return []
            }
        }
        return humps.allSatisfy { $0.count > 1 } ? humps : []
    }
}
