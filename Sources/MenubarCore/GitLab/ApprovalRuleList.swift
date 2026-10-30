import Foundation

/// The approval rules as the merge request detail lists them (MR-06): the rules that need approvals, each once, the
/// open ones first, with a readable name.
///
/// Code owner rules are named by their file pattern, and a `CODEOWNERS` file with sections repeats a pattern once per
/// section, so GitLab sends `*.ts` twice and `*` for everything. The list merges the repeats into one line, which is
/// satisfied only when every repeat is, and names a pattern "Files matching `*.ts`", or "All files".
public struct ApprovalRuleList: Hashable, Sendable {
    /// the open rules, then the satisfied ones, each group in GitLab's order
    public var lines: [Line]

    /// Returns the list of some rules.
    ///
    /// - Parameter rules: GitLab's rules; those that need no approval are left out
    public init(_ rules: [MergeRequestDetails.Rule]) {
        var merged: [Line] = []
        for rule in rules where rule.required > 0 {
            let name = Name(rule.name)
            if let index = merged.firstIndex(where: { $0.name == name }) {
                merged[index].merge(rule)
            } else {
                merged.append(Line(name: name, rule: rule))
            }
        }
        lines = merged.filter { !$0.isSatisfied } + merged.filter(\.isSatisfied)
    }

    /// how many rules still wait for approvals
    public var openCount: Int { lines.filter { !$0.isSatisfied }.count }

    /// One rule, or the repeats of one pattern.
    public struct Line: Hashable, Sendable, Identifiable {
        public var name: Name
        /// how many approvals the rule needs: the most any repeat needs
        public var required: Int
        /// who approved under it, each once
        public var approvedBy: [MergeRequest.Person]
        /// GitLab's verdict, for every repeat
        public var isSatisfied: Bool

        init(name: Name, rule: MergeRequestDetails.Rule) {
            self.name = name
            required = rule.required
            approvedBy = []
            isSatisfied = rule.isSatisfied
            add(rule.approvedBy)
        }

        public var id: Name { name }

        /// "1 of 2"; never more approvals than needed
        public var progress: String {
            "\(min(approvedBy.count, required)) of \(required)"
        }

        mutating func merge(_ rule: MergeRequestDetails.Rule) {
            required = max(required, rule.required)
            isSatisfied = isSatisfied && rule.isSatisfied
            add(rule.approvedBy)
        }

        private mutating func add(_ people: [MergeRequest.Person]) {
            for person in people where !approvedBy.contains(where: { $0.username == person.username }) {
                approvedBy.append(person)
            }
        }
    }

    /// A rule's name: a plain name, a file pattern of a code owner rule, or the pattern for every file.
    public enum Name: Hashable, Sendable {
        /// "Backend Review"
        case named(String)
        /// "Files matching `*.ts`": the pattern
        case files(String)
        /// "All files"
        case allFiles

        /// the patterns that match every file
        private static let everything: Set<String> = ["*", "**", "/*", "/**", "**/*", "/**/*"]

        /// Returns the name of a rule: one word without spaces that has a `*`, a `/` or a `.` is a file pattern.
        ///
        /// - Parameter name: GitLab's rule name
        public init(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if Self.everything.contains(trimmed) {
                self = .allFiles
            } else if !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
                trimmed.contains(where: { "*/.".contains($0) })
            {
                self = .files(trimmed)
            } else {
                self = .named(trimmed.isEmpty ? "Unnamed rule" : trimmed)
            }
        }

        /// the name as plain text: "Backend Review", "Files matching *.ts", "All files"
        public var text: String {
            switch self {
            case .named(let name): name
            case .files(let pattern): "Files matching \(pattern)"
            case .allFiles: "All files"
            }
        }
    }
}
