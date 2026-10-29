#if DEBUG
import Foundation
import MenubarCore

/// The rebuilds of `panel.rebuilding` and `pipelines.rebuilding` (PIPE-09).
extension Fixtures {
    /// One rebuild waiting in Jenkins's queue, which reads "Rebuilding… · Cancel", and one that Jenkins refused for a
    /// missing Build permission.
    ///
    /// - Parameters:
    ///   - queued: the build whose rebuild waits in the queue
    ///   - failed: the build whose rebuild failed
    /// - Returns: the rebuilds per job, as `PipelinesStore.rebuilds` holds them
    func rebuilds(queued: BuildID, failed: BuildID) -> [String: JenkinsRebuild] {
        [
            queued.job: JenkinsRebuild(build: queued, phase: .queued(QueueItem(id: 4711))),
            failed.job: JenkinsRebuild(build: failed, phase: .failed(JenkinsRebuildError.noBuildPermission.message)),
        ]
    }
}
#endif
