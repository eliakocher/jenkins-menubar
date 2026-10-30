import Foundation

/// Asks GitLab about labels: the search of the label picker, and whether the filter labels still exist (WI-06).
public struct LabelSearch: Sendable {
    private let client: GitLabClient?
    private let project: String
    private let clock: any Clock<Duration>

    /// how long the search waits after the last keystroke
    public static let pause: Duration = .milliseconds(300)

    /// - Parameters:
    ///   - client: the GitLab client; `nil` without a GitLab token
    ///   - project: the team's project path, whose labels and those of its groups are searched
    ///   - clock: the clock of the pause
    public init(client: GitLabClient?, project: String, clock: any Clock<Duration> = ContinuousClock()) {
        self.client = client
        self.project = project
        self.clock = clock
    }

    /// Searches the labels whose title contains the text, ignoring case: the remembered labels, the filter labels and
    /// GitLab's (WI-06).
    ///
    /// It waits ``pause`` first. Cancel the task of the previous search when the text changes, so the newer search
    /// wins. Empty text gives the known labels at once, without asking GitLab.
    ///
    /// - Parameters:
    ///   - text: the search text
    ///   - memory: the remembered labels and colors
    ///   - filters: the current filters
    /// - Returns: the labels, their known colors, and the problem when GitLab wasn't asked or didn't answer
    /// - Throws: `CancellationError` when the task was cancelled
    public func searchLabels(_ text: String, memory: LabelMemory, filters: WorkItemFilters) async throws -> LabelSearchResult {
        var found: [Label] = []
        var problem: String?
        if !text.isEmpty {
            try await clock.sleep(for: Self.pause)
            if let client {
                do {
                    found = try await client.send(.labels(project: project, searchTerm: text))
                } catch is GitLabError {
                    problem = LabelSearchResult.noAnswerProblem
                }
            } else {
                problem = LabelSearchResult.noTokenProblem
            }
        }
        // GitLab also finds labels by their description.
        let titles = Set(memory.known + filters.withLabels + filters.withoutLabels + found.map(\.title))
            .filter { text.isEmpty || $0.range(of: text, options: .caseInsensitive) != nil }
            .sorted()
        var colors = memory.colors
        for label in found {
            colors[label.title] = label.color ?? colors[label.title]
        }
        return LabelSearchResult(labels: titles, colors: colors.filter { titles.contains($0.key) }, found: found, problem: problem)
    }

    /// Asks GitLab for the slot labels of the given years: every label of the project and its groups whose title starts
    /// with the slot prefix and a year, like `slot::2026.` (SLOT-02).
    ///
    /// One request per year keeps the 100 labels of an answer for the years that matter. Labels that aren't slots (a
    /// prefix match in the description, a year in a longer name) are left out.
    ///
    /// - Parameters:
    ///   - prefix: the slot label prefix from Team
    ///   - years: the years to ask for
    /// - Returns: the slot labels with their colors, sorted by title; `nil` when GitLab wasn't asked (no token) or a
    ///   request failed, so the caller keeps what it had
    /// - Throws: `CancellationError` when the task was cancelled
    public func slotLabels(prefix: String, years: [Int]) async throws -> [Label]? {
        guard let client, !prefix.isEmpty else { return nil }
        var found: [String: Label] = [:]
        for year in years {
            do {
                for label in try await client.send(.labels(project: project, searchTerm: "\(prefix)\(year).")) {
                    if SlotName(label: label.title, prefix: prefix) != nil {
                        found[label.title] = label
                    }
                }
            } catch is GitLabError {
                return nil
            }
        }
        return found.values.sorted { $0.title < $1.title }
    }

    /// Asks GitLab about every filter label that no loaded work item has, after a load of the work items (WI-06).
    ///
    /// A label GitLab answers without is flagged as gone. When GitLab doesn't answer, a label keeps the flag it had.
    /// The colors GitLab sends are remembered.
    ///
    /// - Parameters:
    ///   - filters: the current filters
    ///   - workItems: the loaded work items
    ///   - memory: the label memory before the check
    /// - Returns: the new memory, and the labels flagged that weren't before, to log once
    /// - Throws: `CancellationError` when the task was cancelled
    public func checkFilterLabels(filters: WorkItemFilters, workItems: [WorkItem], memory: LabelMemory) async throws
        -> FilterLabelCheck
    {
        var memory = memory
        let had = Set(workItems.flatMap(\.labels).map(\.title))
        var missing: [String] = []
        for label in filters.withLabels + filters.withoutLabels where !had.contains(label) {
            guard let client else {
                if memory.missing.contains(label) { missing.append(label) }
                continue
            }
            do {
                let found = try await client.send(.labels(project: project, searchTerm: label))
                memory.remember(colorsOf: found)
                if !found.contains(where: { $0.title == label }) {
                    missing.append(label)
                }
            } catch is GitLabError {
                if memory.missing.contains(label) { missing.append(label) }
            }
        }
        let newlyMissing = missing.filter { !memory.missing.contains($0) }
        memory.missing = missing
        return FilterLabelCheck(memory: memory, newlyMissing: newlyMissing)
    }
}

/// The answer of ``LabelSearch/searchLabels(_:memory:filters:)``.
public struct LabelSearchResult: Hashable, Sendable {
    /// the matching label titles, sorted
    public var labels: [String]
    /// the known colors of those labels, by title
    public var colors: [String: String]
    /// GitLab's labels with their colors, for ``LabelMemory/remember(colorsOf:)``
    public var found: [Label]
    /// why only the labels of the work items show; `nil` when GitLab answered, or wasn't needed
    public var problem: String?

    public init(labels: [String], colors: [String: String], found: [Label], problem: String?) {
        self.labels = labels
        self.colors = colors
        self.found = found
        self.problem = problem
    }

    public static let noTokenProblem = "No GitLab token: only the labels of your work items"
    public static let noAnswerProblem = "GitLab did not answer: only the labels of your work items"
}

/// The answer of ``LabelSearch/checkFilterLabels(filters:workItems:memory:)``.
public struct FilterLabelCheck: Hashable, Sendable {
    /// the label memory with the gone filter labels and the new colors
    public var memory: LabelMemory
    /// the labels flagged now that weren't flagged before, to log once
    public var newlyMissing: [String]

    public init(memory: LabelMemory, newlyMissing: [String]) {
        self.memory = memory
        self.newlyMissing = newlyMissing
    }
}
