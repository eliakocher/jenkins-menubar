#if DEBUG
import AppKit
import MenubarCore
import SwiftUI

extension GalleryCatalog {
    /// One entry per state of `docs/design/alert.md`; the heights fit the content. A failed, unstable or aborted build
    /// has Rebuild after Open Build (PIPE-09); a preview never does.
    @MainActor static var alertEntries: [GalleryEntry] {
        func size(_ height: CGFloat) -> CGSize { CGSize(width: 320, height: height) }
        /// The alert as the window shows it: a failed, unstable or aborted build's Rebuild is a split button.
        @MainActor func alertView(alert: BuildAlert, notificationsOff: Bool, perform: @escaping (AlertContent.Action) -> Void) -> BuildAlertView {
            BuildAlertView(
                alert: alert, notificationsOff: notificationsOff,
                rebuildWithChanges: alert.content.offersRebuild ? {} : nil, perform: perform)
        }
        let head: [GalleryEntry] = [
            GalleryEntry(screen: "alert", state: "success-mr", size: size(433)) { f in
                alertView(alert: f.mergeRequestAlert(.success, minutes: 30), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "success-no-mr", size: size(381)) { f in
                alertView(alert: f.branchAlert(.success, minutes: 30), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "unstable-mr", size: size(499)) { f in
                alertView(
                    alert: f.mergeRequestAlert(.unstable, minutes: 42, failedStages: ["tests"], tests: TestCounts(failed: 2, total: 1200)),
                    notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "unstable-no-mr", size: size(432)) { f in
                alertView(alert: f.branchAlert(.unstable, minutes: 42, tests: TestCounts(failed: 2, total: 1200)),
                               notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "failure-mr", size: size(499)) { f in
                alertView(
                    alert: f.mergeRequestAlert(.failure, minutes: 12, failedStages: ["tests", "deploy"], tests: TestCounts(failed: 3, total: 1200)),
                    notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "failure-no-mr", size: size(432)) { f in
                alertView(alert: f.branchAlert(.failure, minutes: 12, failedStages: ["build"]), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "failure-no-details", size: size(469)) { f in
                alertView(alert: f.mergeRequestAlert(.failure, minutes: 12), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "aborted-mr", size: size(469)) { f in
                alertView(alert: f.mergeRequestAlert(.aborted, minutes: 5), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "aborted-no-mr", size: size(417)) { f in
                alertView(alert: f.branchAlert(.aborted, minutes: 5), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "other-mr", size: size(433)) { f in
                alertView(alert: f.mergeRequestAlert(.notBuilt, minutes: 0), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "other-no-mr", size: size(381)) { f in
                alertView(alert: f.branchAlert(.notBuilt, minutes: 0), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "no-title", size: size(397)) { f in
                alertView(alert: f.mergeRequestAlert(.success, minutes: 30, title: "!1"), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "long-titles", size: size(500)) { f in
                var build = f.finished(
                    "feature%252Fa-very-long-branch-name-for-the-report-export", 12, f.longTitle, .failure, durationMinutes: 65,
                    finishedMinutesAgo: 0, failedStages: ["tests"], tests: TestCounts(failed: 12, total: 4200))
                build.gitLabURL = nil
                return alertView(alert: f.alert(build), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "long-stages", size: size(513)) { f in
                let stages = [
                    "integration-tests-with-a-long-name", "deploy-to-staging", "end-to-end-tests-of-the-report-page",
                    "database-migration-check", "security-scan-of-the-dependencies", "performance-tests-under-load",
                    "accessibility-checks", "documentation-build", "publish-the-release-notes",
                ]
                return alertView(
                    alert: f.mergeRequestAlert(.failure, minutes: 151, title: "Dark mode for the report page", failedStages: stages,
                                               tests: TestCounts(failed: 1234, total: 15000)),
                    notificationsOff: false, perform: { _ in })
            },
            // The easter egg line under the facts, and the hat of the butler (`docs/easter-eggs.md`, rule 7).
            GalleryEntry(screen: "alert", state: "success-egg-line", size: size(471)) { f in
                var alert = f.mergeRequestAlert(.success, minutes: 30)
                alert.content.eggLine = "Three for three today. The butler put on a party hat."
                alert.content.hat = .party
                return alertView(alert: alert, notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "failure-egg-line", size: size(522)) { f in
                var alert = f.mergeRequestAlert(
                    .failure, minutes: 12, failedStages: ["tests", "deploy"], tests: TestCounts(failed: 3, total: 1200))
                alert.content.eggLine = "Third failure in a row. The butler is out of tissues."
                return alertView(alert: alert, notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "preview-success", size: size(417)) { f in
                alertView(alert: BuildAlert.preview(.success, team: f.team)!, notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "preview-failure", size: size(447)) { f in
                alertView(alert: BuildAlert.preview(.failure, team: f.team)!, notificationsOff: false, perform: { _ in })
            },
            // The pop-up with the bigger butler: plain, and in Halloween's hat under a storm (the user, 2026-11-04).
            GalleryEntry(screen: "alert", state: "single-halloween-weather", size: size(545)) { f in
                var alert = f.mergeRequestAlert(
                    .failure, minutes: 12, failedStages: ["tests", "deploy"], tests: TestCounts(failed: 3, total: 1200))
                alert.content.hat = .witch
                alert.content.weather = .storm
                alert.content.funLevel = .party
                var view = alertView(alert: alert, notificationsOff: false, perform: { _ in })
                view.frozenWeatherAt = 1.6
                return view
            },
        ]
        let tail: [GalleryEntry] = [
            // Two or more at once, more rows than fit: the list scrolls (ALERT-03).
            GalleryEntry(screen: "alert", state: "summary-long", size: CGSize(width: 420, height: 520)) { f in
                let titles = [
                    "Fix the login redirect after a timeout", "Speed up the search index rebuild", "Clean up the old report exporter",
                    f.longTitle, "Document the release steps", "Translate the settings pane", "Dark mode for the report page",
                    "Rework the color tokens",
                ]
                let results: [BuildResult] = [.failure, .success, .unstable, .failure, .success, .success, .aborted, .failure]
                return AlertWindowGalleryView(
                    items: titles.indices.map {
                        AlertWindowItem(
                            alert: f.summaryAlert(12500 + $0 * 7, titles[$0], results[$0], minutes: Double(8 + $0 * 5)), notificationsOff: false)
                    })
            },
            // A build I only watch: the "Watching" tag with the author, and no Rebuild.
            GalleryEntry(screen: "alert", state: "failure-watched", size: size(449)) { f in
                alertView(
                    alert: f.watchedAlert(.failure, minutes: 12, failedStages: ["tests"], tests: TestCounts(failed: 3, total: 1200)),
                    notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "success-watched", size: size(419)) { f in
                alertView(alert: f.watchedAlert(.success, minutes: 30), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "failure-watched-no-author", size: size(419)) { f in
                alertView(alert: f.watchedAlert(.failure, minutes: 12, author: nil), notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "failure-watched-long-author", size: size(419)) { f in
                alertView(
                    alert: f.watchedAlert(.failure, minutes: 12, author: "Alexandra Montgomery-Featherstonehaugh"),
                    notificationsOff: false, perform: { _ in })
            },
            GalleryEntry(screen: "alert", state: "notifications-off", size: size(450)) { f in
                alertView(alert: f.mergeRequestAlert(.success, minutes: 30), notificationsOff: true, perform: { _ in })
            },
        ]
        return head + singleVariationEntries + summaryVariationEntries + tail
    }
}

/// The butler's variations, one gallery entry each (the user, 2026-11-04: "screenshots of every variation"). The season is
/// fixed per entry, never today's date, and the heights are the content's: the page without the butler (measured) plus the
/// stage for his art.
extension GalleryCatalog {
    /// a season's hat with its entry's name
    typealias Season = (name: String, hat: ButlerHat?)

    /// plain and the four seasons that have mixed art
    static let summarySeasons: [Season] = [
        ("plain", nil), ("halloween", .witch), ("santa", .santa), ("carnival", .carnival), ("easter", .easter),
    ]
    /// what a build alert has: the same and the party hat
    static let singleSeasons: [Season] = summarySeasons + [("party", .party)]

    /// the height of a page without its butler, in points: a happy build alert (MR, 30 minutes), a sad one (MR, a failed
    /// stage and tests), and a summary of three rows
    private enum PageHeight {
        static let happy: CGFloat = 273
        static let sad: CGFloat = 339
        static let summary: CGFloat = 269
    }

    /// the stage's height for a butler's art, in points
    @MainActor private static func stage(_ art: NSImage) -> CGFloat {
        ButlerStage<EmptyView, EmptyView>.height(
            of: AppImages.alertSize(of: art, box: ButlerStage<EmptyView, EmptyView>.artBox), hasSky: false)
    }

    /// `alert.single-<happy|sad>-<plain|halloween|santa|carnival|easter|party>`: a finished build's pop-up
    @MainActor static var singleVariationEntries: [GalleryEntry] {
        var entries: [GalleryEntry] = []
        for season in singleSeasons {
            for icon in [AlertContent.Icon.happy, .sad] {
                let height = (icon == .happy ? PageHeight.happy : PageHeight.sad) + ceil(stage(AppImages.alert(icon, hat: season.hat)))
                entries.append(
                    GalleryEntry(screen: "alert", state: "single-\(icon.rawValue)-\(season.name)", size: CGSize(width: 320, height: height)) { f in
                        var alert = icon == .happy
                            ? f.mergeRequestAlert(.success, minutes: 30)
                            : f.mergeRequestAlert(.failure, minutes: 12, failedStages: ["tests"], tests: TestCounts(failed: 3, total: 1200))
                        alert.content.hat = season.hat
                        return BuildAlertView(
                            alert: alert, notificationsOff: false, rebuildWithChanges: alert.content.offersRebuild ? {} : nil,
                            perform: { _ in })
                    })
            }
        }
        return entries
    }

    /// `alert.summary-<failed|succeeded|mixed>-<plain|halloween|santa|carnival|easter>`: the summary of three items
    @MainActor static var summaryVariationEntries: [GalleryEntry] {
        var entries: [GalleryEntry] = []
        for season in summarySeasons {
            for butler in ["failed", "succeeded", "mixed"] {
                let art: NSImage = switch butler {
                case "failed": AppImages.alert(.sad, hat: season.hat)
                case "succeeded": AppImages.alert(.happy, hat: season.hat)
                default: AppImages.mixed(hat: season.hat)
                }
                let height = PageHeight.summary + ceil(stage(art))
                entries.append(
                    GalleryEntry(screen: "alert", state: "summary-\(butler)-\(season.name)", size: CGSize(width: 420, height: height)) { f in
                        let failed = [
                            AlertWindowItem(alert: f.summaryAlert(12511, "Fix the login redirect after a timeout", .failure, minutes: 12), notificationsOff: false),
                            AlertWindowItem(alert: f.summaryAlert(12498, "Speed up the search index rebuild", .unstable, minutes: 42), notificationsOff: false),
                            AlertWindowItem(alert: f.branchAlert(.failure, minutes: 9, failedStages: ["build"]), notificationsOff: false),
                        ]
                        let succeeded = [
                            AlertWindowItem(alert: f.summaryAlert(12511, "Fix the login redirect after a timeout", .success, minutes: 31), notificationsOff: false),
                            AlertWindowItem(alert: f.summaryAlert(12498, "Speed up the search index rebuild", .success, minutes: 28), notificationsOff: false),
                            AlertWindowItem(alert: f.branchAlert(.success, minutes: 30), notificationsOff: false),
                        ]
                        // good and bad news, builds and an Inbox event together
                        let mixed = [
                            AlertWindowItem(alert: f.summaryAlert(12511, "Fix the login redirect after a timeout", .failure, minutes: 12), notificationsOff: false),
                            AlertWindowItem(alert: f.summaryAlert(12498, "Speed up the search index rebuild", .success, minutes: 28), notificationsOff: false),
                            AlertWindowItem(event: f.panelEvents["review"]!),
                        ]
                        return AlertWindowGalleryView(items: butler == "failed" ? failed : butler == "succeeded" ? succeeded : mixed, hat: season.hat)
                    })
            }
        }
        return entries
    }
}

/// The alert window as it shows on the Mac: the glass is the window's, so the gallery draws one, a wallpaper and a material
/// clipped to the window's corners. `items` come oldest first, as they arrive.
struct AlertWindowGalleryView: View {
    let items: [AlertWindowItem]
    /// a Done GitLab refused, shown on the Inbox event's page when the window holds only that
    var refusal: Problem?
    /// the season's hat, fixed so that an entry looks the same on every day; none by default
    var hat: ButlerHat?

    var body: some View {
        let model = AlertWindowModel()
        model.hatSource = .fixed(hat)
        for item in items {
            model.items.add(item)
        }
        if let refusal, let id = items.last, case .event(let event) = id.payload {
            model.refusals[event.id] = refusal
        }
        return ZStack {
            LinearGradient(
                colors: [Color(red: 0.86, green: 0.88, blue: 0.93), Color(red: 0.97, green: 0.93, blue: 0.88)], startPoint: .topLeading,
                endPoint: .bottomTrailing)
            AlertWindowView(
                model: model, rebuildWithChanges: { _ in }, perform: { _, _ in }, performEvent: { _, _ in }, openItem: { _ in },
                openInbox: {}, dismissAll: {}, onSizeChange: { _ in }
            )
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: BuildAlertView.cornerRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: BuildAlertView.cornerRadius, style: .continuous))
            .padding(.horizontal, 30)
        }
    }
}
#endif
