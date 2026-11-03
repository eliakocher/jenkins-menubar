import Foundation

// MARK: - What the suggestion works from

/// What GitLab says of a merge request that decides who should review it (MR-15).
public struct ReviewerSuggestionFacts: Hashable, Sendable {
    /// the author's username
    public var author: String
    /// the usernames of the current reviewers
    public var reviewers: [String]
    /// the usernames of those who approved
    public var approvedBy: [String]
    public var targetBranch: String?
    /// the changed files' paths
    public var changedPaths: [String]
    /// GitLab's evaluated approval rules; empty on a GitLab without them
    public var rules: [Rule]

    public init(
        author: String, reviewers: [String] = [], approvedBy: [String] = [], targetBranch: String? = nil,
        changedPaths: [String] = [], rules: [Rule] = []
    ) {
        self.author = author
        self.reviewers = reviewers
        self.approvedBy = approvedBy
        self.targetBranch = targetBranch
        self.changedPaths = changedPaths
        self.rules = rules
    }

    /// One approval rule as GitLab evaluated it for the merge request.
    public struct Rule: Hashable, Sendable {
        /// a code owner rule is named by its pattern
        public var name: String
        public var type: RuleType
        /// a code owner rule's section
        public var section: String?
        /// how many approvals the rule needs; 0 for an optional rule
        public var approvalsRequired: Int
        public var isApproved: Bool
        public var approvedBy: [String]
        /// who may approve under the rule, groups already expanded by GitLab
        public var eligible: [Person]

        public init(
            name: String, type: RuleType, section: String? = nil, approvalsRequired: Int, isApproved: Bool = false,
            approvedBy: [String] = [], eligible: [Person] = []
        ) {
            self.name = name
            self.type = type
            self.section = section
            self.approvalsRequired = approvalsRequired
            self.isApproved = isApproved
            self.approvedBy = approvedBy
            self.eligible = eligible
        }
    }

    /// GitLab's `ApprovalRuleType`.
    public enum RuleType: String, Hashable, Sendable {
        case regular
        case codeOwner
        /// "any approver": names nobody
        case anyApprover
        case reportApprover
        case other

        /// Returns the type of GitLab's enum value.
        ///
        /// - Parameter value: `REGULAR`, `CODE_OWNER`, `ANY_APPROVER`, `REPORT_APPROVER`
        public init(graphQL value: String?) {
            switch value?.uppercased() {
            case "REGULAR": self = .regular
            case "CODE_OWNER": self = .codeOwner
            case "ANY_APPROVER": self = .anyApprover
            case "REPORT_APPROVER": self = .reportApprover
            default: self = .other
            }
        }
    }

    /// A GitLab user as the suggestions know them.
    public struct Person: Hashable, Sendable {
        public var username: String
        /// the full name; empty when GitLab sent none
        public var name: String
        /// whether GitLab says the account is active; unknown counts as active
        public var isActive: Bool
        public var isBot: Bool

        public init(username: String, name: String = "", isActive: Bool = true, isBot: Bool = false) {
            self.username = username
            self.name = name
            self.isActive = isActive
            self.isBot = isBot
        }

        /// Whether a username is a bot's, which GitLab names `project_12_bot_…`, `group_3_bot_…` or `…-bot`, and
        /// `ghost`, `support-bot`, `alert-bot` (inferred from GitLab's naming).
        public var looksLikeBot: Bool {
            isBot || Self.looksLikeBot(username)
        }

        static func looksLikeBot(_ username: String) -> Bool {
            let lower = username.lowercased()
            if lower == "ghost" || lower.hasSuffix("-bot") || lower.hasSuffix("_bot") || lower.hasSuffix("[bot]") {
                return true
            }
            for kind in ["project", "group"] where lower.hasPrefix("\(kind)_") {
                let rest = lower.dropFirst(kind.count + 1)
                if rest.first?.isNumber == true, rest.contains("_bot") {
                    return true
                }
            }
            return false
        }
    }
}

// MARK: - The suggestions

/// A person the app suggests as a reviewer, with why (MR-15).
public struct ReviewerSuggestion: Hashable, Sendable, Identifiable {
    public var username: String
    /// the full name; empty when GitLab sent none
    public var name: String
    public var kind: Kind
    /// the strongest reason: "Required code owner: `*.java` in core", "Required by rule Backend Review", "Code owner:
    /// `*.java` in core", "Squad: Alpha"
    public var reason: String
    /// the other reasons the same person turned up for, each once
    public var otherReasons: [String]
    /// the keys of the open required rules this person's approval counts for
    public var coveredRules: [String]

    public var id: String { username }

    public init(
        username: String, name: String, kind: Kind, reason: String, otherReasons: [String] = [], coveredRules: [String] = []
    ) {
        self.username = username
        self.name = name
        self.kind = kind
        self.reason = reason
        self.otherReasons = otherReasons
        self.coveredRules = coveredRules
    }

    /// the full name, else "@username"
    public var displayName: String { name.isEmpty ? "@\(username)" : name }

    /// whether a rule that blocks the merge needs the person (or someone else of its pool)
    public var isRequired: Bool { kind == .required }

    /// How strong the reason is; the order is the ranking.
    public enum Kind: Int, Comparable, Hashable, Sendable {
        /// an eligible approver of an approval rule that still needs approvals
        case required
        /// the owner of the changed files by `CODEOWNERS`, or by an optional or satisfied code owner rule
        case codeOwner
        /// a member of the author's squad
        case squad

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }
}

/// The ranked suggestions for one merge request.
public struct ReviewerSuggestionList: Hashable, Sendable {
    /// the ranked suggestions: required first
    public var items: [ReviewerSuggestion]
    /// the open required rules by key, with the approvals each still needs
    var openRules: [String: Int]
    /// the open required rules' names by key, for the person: "Backend Review", "*.swift in Core"
    var ruleLabels: [String: String] = [:]
    /// what couldn't be read, like "CODEOWNERS couldn't be read"; the list is what the rest gave
    public var notes: [String]

    public init(items: [ReviewerSuggestion] = [], notes: [String] = []) {
        self.items = items
        self.openRules = [:]
        self.notes = notes
    }

    init(items: [ReviewerSuggestion], openRules: [String: Int], ruleLabels: [String: String] = [:], notes: [String] = []) {
        self.items = items
        self.openRules = openRules
        self.ruleLabels = ruleLabels
        self.notes = notes
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Returns the fewest people who satisfy the open required rules: in the ranking, a suggestion is taken when it
    /// counts for a rule that still needs approvals. "Add Required Reviewers" adds these, not every eligible approver.
    public var minimalRequired: [ReviewerSuggestion] {
        requiredPicks().map(\.person)
    }

    /// One person "Add Required Reviewers" adds, with the open rules their approval counts for.
    public struct RequiredPick: Hashable, Sendable {
        public var person: ReviewerSuggestion
        /// the names of the open rules the person is taken for, like "Backend Review" or "*.swift in Core"
        public var rules: [String]

        public init(person: ReviewerSuggestion, rules: [String]) {
            self.person = person
            self.rules = rules
        }
    }

    /// Returns the people "Add Required Reviewers" adds, the same as ``minimalRequired``, each with the rules they are
    /// taken for: a rule needing two approvals names two people, a person who counts for two rules is one pick.
    ///
    /// - Parameter alreadyAdded: usernames added since the list was read, in any case; their approvals count for their
    ///   rules, and they are not picked again
    /// - Returns: the picks, in the ranking
    public func requiredPicks(alreadyAdded: Set<String> = []) -> [RequiredPick] {
        let added = Set(alreadyAdded.map { $0.lowercased() })
        var remaining = openRules
        for item in items where added.contains(item.username.lowercased()) {
            for key in item.coveredRules where (remaining[key] ?? 0) > 0 {
                remaining[key, default: 0] -= 1
            }
        }
        var picks: [RequiredPick] = []
        for item in items where item.isRequired && !added.contains(item.username.lowercased()) {
            let useful = item.coveredRules.filter { (remaining[$0] ?? 0) > 0 }
            guard !useful.isEmpty else { continue }
            for key in useful {
                remaining[key, default: 0] -= 1
            }
            picks.append(RequiredPick(person: item, rules: useful.map { ruleLabels[$0] ?? $0 }))
        }
        return picks
    }
}

/// Ranks the people who could review a merge request (MR-15), from the sources in this order of strength:
/// GitLab's approval rules, `CODEOWNERS` of the target branch for the changed paths, the author's squad.
///
/// A person found by several sources shows once, with the strongest reason first and the others listed. Left out:
/// the author, the current reviewers, those who approved, bots, and inactive accounts.
public enum ReviewerSuggester {
    /// how many eligible approvers of one rule are suggested: a rule of a big group names dozens
    public static let limitPerRule = 5

    /// Returns the suggestions.
    ///
    /// - Parameters:
    ///   - facts: what GitLab says of the merge request
    ///   - codeOwners: the target branch's `CODEOWNERS`; used only when GitLab's rules hold no code owner rule (a
    ///     GitLab that enforces code owners has evaluated them already)
    ///   - people: what is known of the users `codeOwners` and the squads name
    ///   - peopleAreComplete: whether `people` was asked from GitLab, so a user it lacks doesn't exist and is left out
    ///   - squads: the teams of Settings → Team; the author's teammates are suggested
    ///   - load: each person's open reviews by lowercased username, when known: fewer first among equals
    /// - Returns: the ranked list
    public static func suggest(
        facts: ReviewerSuggestionFacts, codeOwners: CodeOwnersFile? = nil, people: [ReviewerSuggestionFacts.Person] = [],
        peopleAreComplete: Bool = false, squads: SlotTeams? = nil, load: [String: Int] = [:]
    ) -> ReviewerSuggestionList {
        var excluded = Set(([facts.author] + facts.reviewers + facts.approvedBy).map { $0.lowercased() })
        for rule in facts.rules {
            excluded.formUnion(rule.approvedBy.map { $0.lowercased() })
        }
        let known = Dictionary(
            people.map { ($0.username.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let teams = squads?.teams.filter { SlotTeams.contains($0.members, facts.author) } ?? []
        let squadOf: (String) -> [String] = { username in
            teams.filter { SlotTeams.contains($0.members, username) }.map(\.name)
        }

        var builder = Builder(excluded: excluded, known: known, peopleAreComplete: peopleAreComplete, load: load)

        // 1. GitLab's evaluated rules.
        let current = Set(facts.reviewers.map { $0.lowercased() })
        let hasCodeOwnerRules = facts.rules.contains { $0.type == .codeOwner }
        for rule in facts.rules where rule.type != .anyApprover && !rule.isApproved {
            let remaining = max(rule.approvalsRequired - rule.approvedBy.count, 0)
            let eligible = rule.eligible.filter { !$0.looksLikeBot && $0.isActive }
            if remaining > 0, eligible.filter({ current.contains($0.username.lowercased()) }).count >= remaining {
                // The reviewers already on the merge request can satisfy the rule.
                continue
            }
            if remaining == 0, rule.type != .codeOwner {
                continue
            }
            let key = "\(rule.section ?? "")/\(rule.name)"
            let pool = eligible.filter { !excluded.contains($0.username.lowercased()) }
            let ranked = pool.sorted { first, second in
                let (a, b) = (first.username.lowercased(), second.username.lowercased())
                let (aSquad, bSquad) = (!squadOf(a).isEmpty, !squadOf(b).isEmpty)
                if aSquad != bSquad { return aSquad }
                if (load[a] ?? 0) != (load[b] ?? 0) { return (load[a] ?? 0) < (load[b] ?? 0) }
                return a < b
            }
            let label = ruleLabel(rule)
            for person in ranked.prefix(limitPerRule) {
                if remaining > 0 {
                    let oneOf = pool.count > remaining ? " (\(remaining) of \(pool.count) needed)" : ""
                    let text = rule.type == .codeOwner ? "Required code owner: \(label)" : "Required by rule \(label)"
                    builder.add(person, kind: .required, reason: text + oneOf, rule: key, isVerified: true)
                } else {
                    builder.add(person, kind: .codeOwner, reason: "Code owner: \(label)", rule: nil, isVerified: true)
                }
            }
            if remaining > 0 {
                builder.openRules[key] = remaining
                builder.ruleLabels[key] = label.replacingOccurrences(of: "`", with: "")
            }
        }

        // 2. CODEOWNERS, when GitLab didn't evaluate it.
        if !hasCodeOwnerRules, let codeOwners {
            for match in codeOwners.matches(for: facts.changedPaths) {
                let pattern = "`\(match.pattern)`"
                let place = match.section.map { " in \($0)" } ?? ""
                let text = (match.isOptional ? "Optional code owner: " : "Code owner: ") + pattern + place
                for case .user(let username) in match.owners {
                    builder.add(
                        .init(username: username, name: known[username.lowercased()]?.name ?? ""), kind: .codeOwner, reason: text,
                        rule: nil, weight: match.paths.count)
                }
            }
        }

        // 3. The squad.
        for team in teams {
            for member in team.members {
                builder.add(
                    .init(username: member, name: known[member.lowercased()]?.name ?? ""), kind: .squad,
                    reason: "Squad: \(team.name)", rule: nil)
            }
        }

        return builder.list(squadOf: squadOf)
    }

    /// "`*.java`", "all files", "Backend Review", and the section of a code owner rule: "`*.java` in core"
    private static func ruleLabel(_ rule: ReviewerSuggestionFacts.Rule) -> String {
        let name: String
        switch ApprovalRuleList.Name(rule.name) {
        case .files(let pattern): name = rule.type == .codeOwner ? "`\(pattern)`" : pattern
        case .allFiles: name = "all files"
        case .named(let text): name = text
        }
        if rule.type == .codeOwner, let section = rule.section, !section.isEmpty,
            section.caseInsensitiveCompare("Code Owners") != .orderedSame, section.caseInsensitiveCompare("codeowners") != .orderedSame
        {
            return "\(name) in \(section)"
        }
        return name
    }

    /// Collects the reasons per person.
    private struct Builder {
        struct Reason {
            var kind: ReviewerSuggestion.Kind
            var text: String
            var weight: Int
        }

        struct Candidate {
            var username: String
            var name: String
            var reasons: [Reason] = []
            var rules: [String] = []
        }

        let excluded: Set<String>
        let known: [String: ReviewerSuggestionFacts.Person]
        let peopleAreComplete: Bool
        let load: [String: Int]
        var openRules: [String: Int] = [:]
        var ruleLabels: [String: String] = [:]
        private var order: [String] = []
        private var candidates: [String: Candidate] = [:]

        init(excluded: Set<String>, known: [String: ReviewerSuggestionFacts.Person], peopleAreComplete: Bool, load: [String: Int]) {
            self.excluded = excluded
            self.known = known
            self.peopleAreComplete = peopleAreComplete
            self.load = load
        }

        mutating func add(
            _ person: ReviewerSuggestionFacts.Person, kind: ReviewerSuggestion.Kind, reason: String, rule: String?, weight: Int = 1,
            isVerified: Bool = false
        ) {
            let key = person.username.lowercased()
            guard !excluded.contains(key) else { return }
            // What the lookup says of a user beats what a code owner line gave; an eligible approver GitLab named exists.
            let resolved = known[key] ?? (peopleAreComplete && !isVerified ? nil : person)
            guard let resolved, resolved.isActive, !resolved.looksLikeBot, !person.looksLikeBot else { return }
            var candidate = candidates[key] ?? Candidate(username: resolved.username, name: resolved.name.isEmpty ? person.name : resolved.name)
            if candidates[key] == nil {
                order.append(key)
            }
            if !candidate.reasons.contains(where: { $0.text == reason }) {
                candidate.reasons.append(Reason(kind: kind, text: reason, weight: weight))
            }
            if let rule, !candidate.rules.contains(rule) {
                candidate.rules.append(rule)
            }
            candidates[key] = candidate
        }

        func list(squadOf: (String) -> [String]) -> ReviewerSuggestionList {
            var squadReasons: [String: [String]] = [:]
            for key in order {
                squadReasons[key] = squadOf(key).map { "Squad: \($0)" }
            }
            let ranked = order.compactMap { candidates[$0] }.sorted { first, second in
                let (a, b) = (first.username.lowercased(), second.username.lowercased())
                let (aKind, bKind) = (Self.kind(first), Self.kind(second))
                if aKind != bKind { return aKind < bKind }
                let (aCount, bCount) = (Self.strength(first), Self.strength(second))
                if aCount != bCount { return aCount > bCount }
                let (aSquad, bSquad) = (!(squadReasons[a] ?? []).isEmpty, !(squadReasons[b] ?? []).isEmpty)
                if aSquad != bSquad { return aSquad }
                if (load[a] ?? 0) != (load[b] ?? 0) { return (load[a] ?? 0) < (load[b] ?? 0) }
                return a < b
            }
            let items = ranked.map { candidate -> ReviewerSuggestion in
                let strongest = candidate.reasons.min { lhs, rhs in
                    lhs.kind != rhs.kind ? lhs.kind < rhs.kind : lhs.weight > rhs.weight
                } ?? candidate.reasons[0]
                var others = candidate.reasons.map(\.text).filter { $0 != strongest.text }
                for squad in squadReasons[candidate.username.lowercased()] ?? [] where squad != strongest.text && !others.contains(squad) {
                    others.append(squad)
                }
                return ReviewerSuggestion(
                    username: candidate.username, name: candidate.name, kind: strongest.kind, reason: strongest.text,
                    otherReasons: others, coveredRules: candidate.rules)
            }
            return ReviewerSuggestionList(items: items, openRules: openRules, ruleLabels: ruleLabels)
        }

        private static func kind(_ candidate: Candidate) -> ReviewerSuggestion.Kind {
            candidate.reasons.map(\.kind).min() ?? .squad
        }

        /// how much the person counts for: the open rules and the changed files they own
        private static func strength(_ candidate: Candidate) -> Int {
            candidate.rules.count * 1000 + candidate.reasons.filter { $0.kind == .codeOwner }.reduce(0) { $0 + $1.weight }
        }
    }
}
