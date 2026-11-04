import Foundation

/// Tells that a failed Jenkins build and GitLab's "My MR's GitLab Pipeline Failed" are one failure, so the Inbox keeps one entry
/// of it (the user, 2026-11-03: a failure shouldn't show up twice).
///
/// A failed build is about a merge request in one of two ways: its job is named `MR-<iid>`, or it is a branch job named
/// like the merge request's source branch. The match is made, most certain first, by:
/// 1. the build's GitLab page being the merge request's page;
/// 2. the iid of `MR-<iid>` being the iid of the merge request's reference (and the page, when both are known, being in
///    the same project);
/// 3. the branch job's name being the merge request's source branch.
public enum InboxFailureMatching {
    /// the kinds of a failed build's entry
    static let failedBuildKinds: Set<InboxEventKind> = [.buildFailed, .watchedBuildFailed]

    /// Returns whether a failed build and a failed pipeline are about the same merge request.
    ///
    /// - Parameters:
    ///   - build: the entry of a failed build
    ///   - pipeline: the event of a failed pipeline (``InboxEventKind/pipelineFailed``)
    public static func isSameFailure(build: InboxEvent, pipeline: InboxEvent) -> Bool {
        guard failedBuildKinds.contains(build.kind), pipeline.kind == .pipelineFailed else {
            return false
        }
        if let page = build.relatedURL, let target = pipeline.targetURL, same(page, target) {
            return true
        }
        guard let job = jobName(of: build) else {
            return false
        }
        if let iid = Build.mergeRequestIID(forJob: job) {
            guard iid == mergeRequestIID(of: pipeline) else {
                return false
            }
            // The same number in another project is another merge request.
            if let page = build.relatedURL, let path = pipeline.projectPath {
                return page.path.hasPrefix("/\(path)/")
            }
            return true
        }
        guard let branch = pipeline.sourceBranch, !branch.isEmpty else {
            return false
        }
        return Build.label(forJob: job) == branch
    }

    /// the job's name in a build entry's id, `build|<job key>|<number>`, as Jenkins URLs have it
    static func jobName(of build: InboxEvent) -> String? {
        let parts = build.id.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "build" else {
            return nil
        }
        let key = parts[1..<(parts.count - 1)].joined(separator: "|")
        return key.isEmpty ? nil : BuildID.split(jobKey: key).job
    }

    /// the iid of a merge request's reference, like 123 for `group/project!123`
    private static func mergeRequestIID(of pipeline: InboxEvent) -> Int? {
        guard let reference = pipeline.reference, let sign = reference.lastIndex(of: "!") else {
            return nil
        }
        return Int(reference[reference.index(after: sign)...])
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        func normalized(_ url: URL) -> String {
            url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        }
        return normalized(a) == normalized(b)
    }
}

extension InboxFailureMatching {
    /// What one failure, one entry does to a batch of new events.
    public struct Outcome: Equatable, Sendable {
        /// the events to keep: the batch without the failed pipelines whose failed build is in the Inbox already
        public var events: [InboxEvent]
        /// the ids of the pending entries to mark done: GitLab's failed pipeline, seen first, of a merge request whose
        /// failed build arrives now
        public var resolve: Set<String>
    }

    /// Applies the rule to the new events.
    ///
    /// - A failed pipeline isn't added when a failed build of the same merge request is in the Inbox: pending, or from
    ///   the half hour before (the user may have marked it done already), or in this batch.
    /// - A failed build that arrives while GitLab's failed pipeline of the same merge request is pending marks that
    ///   entry done, so the Inbox keeps the build's. Only the entries seen in the merge request lists can be resolved:
    ///   a GitLab to-do belongs to GitLab's list.
    ///
    /// - Parameters:
    ///   - fresh: the events not announced before
    ///   - entries: the local entries of the Inbox
    /// - Returns: the events to keep, and the entries to mark done
    public static func apply(to fresh: [InboxEvent], entries: [InboxLocalEntry]) -> Outcome {
        let buildsInBatch = fresh.filter { failedBuildKinds.contains($0.kind) }
        var kept: [InboxEvent] = []
        for event in fresh {
            if event.kind == .pipelineFailed {
                let builds = entries.filter { entry in
                    failedBuildKinds.contains(entry.event.kind)
                        && (entry.doneAt == nil
                            || abs(event.occurredAt.timeIntervalSince(entry.event.occurredAt)) < InboxAnnouncements.coalesceWindow)
                }.map(\.event) + buildsInBatch
                if builds.contains(where: { isSameFailure(build: $0, pipeline: event) }) {
                    continue
                }
            }
            kept.append(event)
        }
        var resolve = Set<String>()
        for build in buildsInBatch {
            for entry in entries
            where entry.doneAt == nil && entry.event.kind == .pipelineFailed && entry.event.source == .mergeRequests
                && isSameFailure(build: build, pipeline: entry.event)
            {
                resolve.insert(entry.event.id)
            }
        }
        return Outcome(events: kept, resolve: resolve)
    }
}
