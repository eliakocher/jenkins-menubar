import Foundation

/// Holds the pop-up or banner of GitLab's "pipeline failed" for a moment, so that a failed Jenkins build of the same merge
/// request, which comes a little later, can replace it: the user sees one pop-up of a failure, the build's (the user,
/// 2026-11-04: he saw both for !12511).
///
/// The event's Inbox entry exists as usual; only its announcement waits ``grace``. A failed build that
/// ``InboxFailureMatching/isSameFailure(build:pipeline:)`` says is the same failure drops it; when the time is over without
/// one, it is shown then. Only ``InboxEventKind/pipelineFailed`` is held.
@MainActor
final class HeldPipelineAlerts {
    /// how long GitLab's pop-up waits for the failed build of the same merge request
    static let grace: Duration = .seconds(120)

    private struct Held {
        var event: InboxEvent
        var task: Task<Void, Never>
    }

    private var held: [String: Held] = [:]

    /// the events waiting now
    var count: Int { held.count }

    /// Holds an event's announcement for ``grace``, then shows it unless a matching build dropped it.
    ///
    /// - Parameters:
    ///   - event: the failed pipeline
    ///   - clock: the clock of the wait
    ///   - show: shows the event, once the time is over
    func hold(_ event: InboxEvent, clock: any Clock<Duration>, show: @escaping @MainActor (InboxEvent) async -> Void) {
        guard held[event.id] == nil else {
            return
        }
        let task = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.grace)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.held.removeValue(forKey: event.id) != nil else {
                return
            }
            await show(event)
        }
        held[event.id] = Held(event: event, task: task)
    }

    /// Drops the held events that a failed build is the same failure as.
    ///
    /// - Parameter build: the Inbox entry of the failed build
    func drop(matching build: InboxEvent) {
        let same = held.filter { InboxFailureMatching.isSameFailure(build: build, pipeline: $0.value.event) }
        for (id, item) in same {
            item.task.cancel()
            held[id] = nil
        }
    }
}
