import Foundation
import Observation

/// The window's "In GitLab" search (WIN-07): while the search field has text, it asks GitLab for the merge requests or
/// work items beyond my lists, in the team's groups and projects.
///
/// - The search waits 400 ms after the last keystroke, and asks only for at least three characters. A new text cancels the
///   one before; a request never starts while another one is in flight.
/// - An answer is reused for five minutes for the same text, in the same section.
/// - A reference or link isn't searched: it is one item, shown as a direct hit by the view (``intent(for:)``).
@Observable @MainActor
public final class GitLabSearchStore {
    /// How the search of the current text stands.
    public enum Phase: Equatable, Sendable {
        /// nothing is searched: no text yet, too short, or a reference
        case idle
        /// waiting for the pause, or for GitLab
        case loading
        /// the answer, in order, at most ``GitLabSearchRules/limit`` hits
        case loaded([GitLabSearchHit])
        case failed(Problem)
    }

    private struct Key: Hashable {
        var kind: GitLabSearchKind
        /// the text in lowercase, which GitLab doesn't tell apart
        var text: String
    }

    @ObservationIgnored private let services: GitLabServices?
    @ObservationIgnored private var current: Key?
    @ObservationIgnored private var storedPhase: Phase = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cache: [Key: (time: Date, hits: [GitLabSearchHit])] = [:]
    /// bumps when the phase or the text it belongs to changes, which is what views observe
    private var revision = 0

    /// - Parameter services: what asks GitLab; `nil` asks nothing, as in the tests and the gallery
    public init(services: GitLabServices? = nil) {
        self.services = services
    }

    /// Returns what a text asks for.
    ///
    /// - Parameter text: the search field's text
    /// - Returns: nothing, a direct hit or a text to find
    public func intent(for text: String) -> GitLabSearchRules.Intent {
        guard let services else {
            return .none
        }
        let projects = services.team.projects()
        return GitLabSearchRules.intent(for: text, projects: projects, defaultProject: projects.first?.team.gitLabProject ?? "")
    }

    /// Returns how the search of a text stands.
    ///
    /// - Parameters:
    ///   - kind: the section's kind of item
    ///   - text: the search field's text
    /// - Returns: the phase; ``Phase/idle`` for any text but the one searched last
    public func phase(kind: GitLabSearchKind, text: String) -> Phase {
        _ = revision
        guard case .text(let query) = intent(for: text), current == Key(kind: kind, text: query.lowercased()) else {
            return .idle
        }
        return storedPhase
    }

    /// Follows the search field: starts, restarts or stops the search. Call it whenever the text or the section changes.
    ///
    /// - Parameters:
    ///   - kind: the section's kind of item
    ///   - text: the search field's text
    public func update(kind: GitLabSearchKind, text: String) {
        guard case .text(let query) = intent(for: text), let services else {
            stop()
            return
        }
        let key = Key(kind: kind, text: query.lowercased())
        let cached = cache[key].flatMap { services.now().timeIntervalSince($0.time) < GitLabSearchRules.cachedFor ? $0.hits : nil }
        // The same text again changes nothing, unless its answer expired or failed.
        if current == key, storedPhase == .loading || (cached != nil && storedPhase != .idle) {
            return
        }
        let previous = task
        previous?.cancel()
        current = key
        if let cached {
            task = nil
            set(.loaded(cached))
            return
        }
        set(.loading)
        task = Task { [weak self] in
            // The request of the text before ends first, so two never run together.
            await previous?.value
            do {
                try await services.clock.sleep(for: GitLabSearchRules.pause)
            } catch {
                return
            }
            await self?.run(key, text: query)
        }
    }

    /// Stops the search and forgets its result, as when the search field is cleared.
    public func stop() {
        task?.cancel()
        task = nil
        current = nil
        set(.idle)
    }

    // MARK: - Private

    private func set(_ phase: Phase) {
        storedPhase = phase
        revision += 1
    }

    private func run(_ key: Key, text: String) async {
        guard let services, current == key, !Task.isCancelled else {
            return
        }
        let result: Result<[GitLabSearchHit], GitLabError>
        do {
            let client = try await services.session().get().client
            let scopes = GitLabSearchRules.scopes(of: services.team.projects())
            let operation: GitLabOperation<[GitLabSearchHit]> =
                switch key.kind {
                case .mergeRequest: .searchMergeRequests(text: text, groups: scopes.groups, projects: scopes.projects)
                case .workItem: .searchWorkItems(text: text, groups: scopes.groups, projects: scopes.projects)
                }
            result = .success(GitLabSearchRules.ordered(try await client.send(operation)))
        } catch let error as GitLabError {
            result = .failure(error)
        } catch {
            // A cancelled request is the next text's business.
            guard !Task.isCancelled else {
                return
            }
            result = .failure(GitLabError(.unreachable(.gitLab)))
        }
        // A newer text took over while GitLab answered.
        guard current == key, !Task.isCancelled else {
            return
        }
        switch result {
        case .success(let hits):
            cache[key] = (services.now(), hits)
            if cache.count > 40, let oldest = cache.min(by: { $0.value.time < $1.value.time })?.key {
                cache[oldest] = nil
            }
            set(.loaded(hits))
        case .failure(let error):
            set(.failed(error.problem))
        }
    }
}
