import Foundation
import Observation

/// Every slot label GitLab has for the team's slot prefix, loaded while the Slots section shows, so that the current and
/// the upcoming slots show whether or not one of the user's work items is in them (SLOT-02).
///
/// It shows the cached labels at once. A failed load keeps them and says so in ``problem``, a quiet note: the plan then
/// builds its slots from the labels of the work items and the remembered ones, as before.
@Observable @MainActor
public final class SlotLabelsStore {
    /// how long an answer is reused before the section asks again
    public nonisolated static let reusedFor: TimeInterval = 600
    public nonisolated static let noAnswerProblem = "GitLab did not answer: only the slots of your work items and the remembered ones"

    /// the slot labels as last loaded, with GitLab's colors
    public private(set) var labels: [Label]
    /// when ``labels`` was loaded; `nil` before the first load
    public private(set) var fetchedAt: Date?
    /// why the labels aren't GitLab's current answer; `nil` when the last load worked
    public private(set) var problem: String?
    public private(set) var isLoading = false

    @ObservationIgnored private let services: GitLabServices
    @ObservationIgnored private let project: ProjectID
    @ObservationIgnored private let calendar: Calendar

    /// - Parameters:
    ///   - services: the transport, the token, the team values and the caches
    ///   - calendar: the calendar whose year decides which years to ask for
    public init(services: GitLabServices, calendar: Calendar = .current) {
        self.services = services
        self.calendar = calendar
        project = services.team.primaryProject().id
        let cached = services.caches.load(.slotLabels, for: project)
        labels = cached?.value ?? []
        fetchedAt = cached?.fetchedAt
    }

    /// Loads the slot labels of this year and the next, unless an answer younger than ``reusedFor`` is there.
    ///
    /// Without a slot prefix nothing is asked. A load that is cancelled keeps what was there.
    ///
    /// - Parameter force: asks even when the last answer is recent
    public func load(force: Bool = false) async {
        let prefix = services.team.primaryProject().team.slotLabelPrefix
        guard !prefix.isEmpty, !isLoading else { return }
        if !force, problem == nil, let fetchedAt, services.now().timeIntervalSince(fetchedAt) < Self.reusedFor { return }
        isLoading = true
        defer { isLoading = false }
        guard case .success(let session) = await services.session() else {
            // A missing token or team value is a setup step that the section already shows.
            problem = nil
            return
        }
        let year = calendar.component(.yearForWeekOfYear, from: services.now())
        let search = LabelSearch(client: session.client, project: session.path, clock: services.clock)
        do {
            if let found = try await search.slotLabels(prefix: prefix, years: [year, year + 1]) {
                labels = found
                fetchedAt = services.now()
                problem = nil
                try? services.caches.save(Cached(value: found, fetchedAt: services.now()), as: .slotLabels, for: project)
            } else {
                problem = Self.noAnswerProblem
            }
        } catch {
            // cancelled: keep what was there
        }
    }
}

extension CacheFile where Value == [Label] {
    /// the slot labels of the team's slot prefix (SLOT-02)
    public static var slotLabels: CacheFile { CacheFile("slot-labels") }
}
