#if DEBUG
import MenubarCore
import SwiftUI

/// The README's screenshots: `scripts/readme-shots.sh` renders these entries (and a few of the others) in dark with
/// `--readme`, which gives their windows the app's own look (no entry id in a title bar). Every entry shows a busy,
/// plausible team from the made-up fixtures, in a window of 1400 x 900 points; the pane and the alert keep their own
/// sizes. Names and numbers here are stable on purpose: the script copies the shots to `docs/screenshots/`.
extension GalleryCatalog {
    static var readmeEntries: [GalleryEntry] {
        let window = CGSize(width: 1400, height: 900)
        return [
            // The first image of the README: Pipelines with a running build, its stages and parameters.
            GalleryEntry(screen: "readme", state: "main-window", size: window) { f in
                PipelinesGalleryView(data: f.readmePipelines, selection: "MR-12", size: window)
            },
            // The menu bar pane with the Pipelines flyout.
            GalleryEntry(screen: "readme", state: "pane", size: CGSize(width: 832, height: 461)) { f in
                MenuPaneGalleryView(data: f.menuPaneData, open: .pipelines, flyoutHighlight: 1)
                    .frame(width: 832, height: 461)
            },
            // A failed build: its stages, the failed tests and the console log, open at the end of the log.
            GalleryEntry(screen: "readme", state: "pipelines", size: CGSize(width: 1400, height: 1120)) { f in
                PipelinesGalleryView(
                    data: f.readmePipelines, selection: "MR-16", size: CGSize(width: 1400, height: 1120), failedTests: .standard
                )
                .environment(
                    \.consoleLogFixture,
                    Self.readmeConsoleLog(lines: 20_000))
            },
            GalleryEntry(screen: "readme", state: "merge-request", size: window) { f in
                let m = f.mergeRequestsScreen
                return MergeRequestsGalleryView(panel: m.panel(m.sections + [m.mr16]), selection: m.mr16.id, size: window)
                    .environment(
                        \.mergeRequestDetailsFixtures,
                        MergeRequestDetailsFixtures(
                            states: [m.mr16.reference: .loaded(m.details16)], writeAccess: .allowed,
                            changes: [m.mr16.reference: .loaded(m.changes16)],
                            mergeStates: [m.mr16.reference: MergeStateLoad(state: m.mergeBlocked)]))
            },
            // A work item: the facts panel, its merge requests with their builds, the slot, the description.
            GalleryEntry(screen: "readme", state: "work-item", size: CGSize(width: 1100, height: 900)) { f in
                WorkItemDetailGalleryView(fixtures: f, sparse: false, size: CGSize(width: 1100, height: 900))
            },
            GalleryEntry(screen: "readme", state: "slots", size: window) { f in
                SlotsGalleryView(fixtures: f, size: window)
            },
            GalleryEntry(screen: "readme", state: "inbox", size: window) { f in
                InboxGalleryView(data: f.inboxData(), panel: f.panel(), seen: f.inboxSeen, size: window)
            },
            GalleryEntry(screen: "readme", state: "digest", size: window) { f in
                DigestGalleryView(
                    fixtures: f, state: DigestGalleryView.full(f), size: window, morningMinutes: 8 * 60 + 30, unread: false)
            },
            GalleryEntry(screen: "readme", state: "workspaces", size: window) { f in
                let w = f.workspacesScreen
                return WorkspacesGalleryView(fixtures: f, data: w.data(), selection: w.checkout(2).id, size: window)
            },
            // Settings → Menu Bar with its preview, tall enough for the whole list.
            GalleryEntry(screen: "readme", state: "settings-menu-bar", size: CGSize(width: SettingsMetrics.width, height: 1026)) { f in
                reuse("settings-menu-bar.typical", f).frame(width: SettingsMetrics.width, height: 1026, alignment: .top)
            },
            // The alert of a failed build, one of five pages.
            GalleryEntry(screen: "readme", state: "alert", size: CGSize(width: 320, height: 459)) { f in
                reuse("alert.paged-5", f).background(Color(nsColor: .windowBackgroundColor))
            },
        ]
    }
}

extension GalleryCatalog {
    /// The view of another gallery entry, which the README shows as it is.
    @MainActor
    fileprivate static func reuse(_ id: String, _ fixtures: Fixtures) -> AnyView {
        entries.first { $0.id == id }?.makeView(fixtures) ?? AnyView(EmptyView())
    }

    /// A console log in memory, open, in place of Jenkins.
    @MainActor
    fileprivate static func readmeConsoleLog(lines: Int) -> ConsoleLogFixture {
        let stored = ConsoleLogFake.pipelineLog(lines: lines)
        let fake = ConsoleLogFake(stored: stored, isRunning: false)
        return ConsoleLogFixture(source: fake.source, startsOpen: true) { loader in
            loader.preload(stored: stored, isRunning: false)
        }
    }
}

extension Fixtures {
    /// A busy morning of Pipelines for the README: running, failed, unstable and passed builds of the team's merge
    /// requests, and two watched.
    var readmePipelines: PipelinesData {
        let tests = stages([("checkout", .success, 0.5), ("build", .success, 4), ("tests", .success, 9), ("deploy", .success, 3)])
        let passed = pipelineBuild(
            "MR-21", 4, "Remove the old onboarding page", phase: .finished(result: .success, duration: 18 * 60),
            startedMinutesAgo: 40, stages: tests)
        let passedAgain = pipelineBuild(
            "MR-27", 2, "Cache the label colors per project", phase: .finished(result: .success, duration: 16 * 60),
            startedMinutesAgo: 95, stages: tests)
        let second = pipelineBuild(
            "MR-23", 1, "Speed up the CSV export", phase: .running, startedMinutesAgo: 6, estimateMinutes: 20,
            stages: stages([("checkout", .success, 0.5), ("build", .inProgress, 3)]), kind: .watched, author: "Alex Kim")
        return pipelines(
            mine: pipelineBuilds + [passed, passedAgain], watched: [watchedBuild, second])
    }
}
#endif
