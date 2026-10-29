#if DEBUG
import MenubarCore
import SwiftUI

extension GalleryCatalog {
    /// One entry per state of `docs/design/alert.md`; the heights fit the content. A failed, unstable or aborted build
    /// has Rebuild after Open Build (PIPE-09); a preview never does.
    static var alertEntries: [GalleryEntry] {
        func size(_ height: CGFloat) -> CGSize { CGSize(width: 320, height: height) }
        return [
            GalleryEntry(screen: "alert", state: "success-mr", size: size(350)) { f in
                BuildAlertView(alert: f.mergeRequestAlert(.success, minutes: 30), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "success-no-mr", size: size(300)) { f in
                BuildAlertView(alert: f.branchAlert(.success, minutes: 30), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "unstable-mr", size: size(416)) { f in
                BuildAlertView(
                    alert: f.mergeRequestAlert(.unstable, minutes: 42, failedStages: ["tests"], tests: TestCounts(failed: 2, total: 1200)),
                    notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "unstable-no-mr", size: size(346)) { f in
                BuildAlertView(alert: f.branchAlert(.unstable, minutes: 42, tests: TestCounts(failed: 2, total: 1200)),
                               notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "failure-mr", size: size(416)) { f in
                BuildAlertView(
                    alert: f.mergeRequestAlert(.failure, minutes: 12, failedStages: ["tests", "deploy"], tests: TestCounts(failed: 3, total: 1200)),
                    notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "failure-no-mr", size: size(346)) { f in
                BuildAlertView(alert: f.branchAlert(.failure, minutes: 12, failedStages: ["build"]), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "failure-no-details", size: size(386)) { f in
                BuildAlertView(alert: f.mergeRequestAlert(.failure, minutes: 12), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "aborted-mr", size: size(386)) { f in
                BuildAlertView(alert: f.mergeRequestAlert(.aborted, minutes: 5), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "aborted-no-mr", size: size(336)) { f in
                BuildAlertView(alert: f.branchAlert(.aborted, minutes: 5), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "other-mr", size: size(350)) { f in
                BuildAlertView(alert: f.mergeRequestAlert(.notBuilt, minutes: 0), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "other-no-mr", size: size(300)) { f in
                BuildAlertView(alert: f.branchAlert(.notBuilt, minutes: 0), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "no-title", size: size(320)) { f in
                BuildAlertView(alert: f.mergeRequestAlert(.success, minutes: 30, title: "!1"), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "long-titles", size: size(416)) { f in
                var build = f.finished(
                    "feature%252Fa-very-long-branch-name-for-the-report-export", 12, f.longTitle, .failure, durationMinutes: 65,
                    finishedMinutesAgo: 0, failedStages: ["tests"], tests: TestCounts(failed: 12, total: 4200))
                build.gitLabURL = nil
                return BuildAlertView(alert: f.alert(build), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "long-stages", size: size(436)) { f in
                let stages = [
                    "integration-tests-with-a-long-name", "deploy-to-staging", "end-to-end-tests-of-the-report-page",
                    "database-migration-check", "security-scan-of-the-dependencies", "performance-tests-under-load",
                    "accessibility-checks", "documentation-build", "publish-the-release-notes",
                ]
                return BuildAlertView(
                    alert: f.mergeRequestAlert(.failure, minutes: 151, title: "Dark mode for the report page", failedStages: stages,
                                               tests: TestCounts(failed: 1234, total: 15000)),
                    notificationsOff: false, perform: { _ in })
            },
            // The easter egg line under the facts, and the hat of the butler (`docs/easter-eggs.md`, rule 7).
            GalleryEntry(screen: "alert", state: "success-egg-line", size: size(376)) { f in
                var alert = f.mergeRequestAlert(.success, minutes: 30)
                alert.content.eggLine = "Three for three today. The butler put on a party hat."
                alert.content.hat = .party
                return BuildAlertView(alert: alert, notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "failure-egg-line", size: size(436)) { f in
                var alert = f.mergeRequestAlert(
                    .failure, minutes: 12, failedStages: ["tests", "deploy"], tests: TestCounts(failed: 3, total: 1200))
                alert.content.eggLine = "Third failure in a row. The butler is out of tissues."
                return BuildAlertView(alert: alert, notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "preview-success", size: size(350)) { f in
                BuildAlertView(alert: BuildAlert.preview(.success, team: f.team)!, notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "preview-failure", size: size(380)) { f in
                BuildAlertView(alert: BuildAlert.preview(.failure, team: f.team)!, notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "notifications-off", size: size(390)) { f in
                BuildAlertView(alert: f.mergeRequestAlert(.success, minutes: 30), notificationsOff: true, perform: { _ in })
            },
        ]
    }
}
#endif
