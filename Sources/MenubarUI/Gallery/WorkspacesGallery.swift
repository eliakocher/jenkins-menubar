#if DEBUG
import MenubarCore
import SwiftUI

/// The made-up checkouts of the Workspaces section: six full clones side by side in `~/workspaces/*/project`, as the
/// plan's team works, one free, one free with a stale `develop`, tasks with and without merge requests, one with changed
/// files and one git couldn't read.
struct WorkspacesFixtures {
    let f: Fixtures

    var home: URL { URL(filePath: "/Users/jdoe", directoryHint: .isDirectory) }
    let folder = RepositoryFolder(
        id: UUID(uuidString: "6D1C9A52-0F3B-4A57-9D0B-5E8F4C2B7A10")!, path: "~/workspaces/*/project")

    func checkout(_ number: Int) -> Checkout {
        Checkout(
            path: "/Users/jdoe/workspaces/develop\(number)/project", name: "develop\(number)", baseBranch: "develop",
            folder: folder.id)
    }

    var checkouts: [Checkout] { (1...6).map(checkout) }

    /// develop2's work item, loaded
    var loginItem: WorkItem {
        WorkItem(
            reference: "group/subgroup/project#1234", title: "Fix the login timeout for SSO users",
            webURL: URL(string: "https://gitlab.example.com/group/subgroup/project/-/issues/1234")!, updatedAt: f.minutesAgo(30))
    }

    /// develop5's work item, loaded
    var darkModeItem: WorkItem {
        WorkItem(
            reference: "group/subgroup/project#1288", title: "Dark mode for the agent console",
            webURL: URL(string: "https://gitlab.example.com/group/subgroup/project/-/issues/1288")!, updatedAt: f.minutesAgo(90))
    }

    var mergeRequests: [MergeRequest] {
        var login = f.mergeRequest(87, "Fix the login timeout for SSO users")
        login.sourceBranch = "1234-fix-login-timeout-for-sso-users"
        var export = f.mergeRequest(91, "Draft: Export the audit log as CSV", status: .draftStatus, draft: true, pipeline: .running)
        export.sourceBranch = "1302-export-audit-log-as-csv"
        return [login, export]
    }

    var builds: [Build] {
        [
            f.finished("MR-87", 12, "Fix the login timeout for SSO users", .success, durationMinutes: 38, finishedMinutesAgo: 25),
            f.running("MR-91", 4, "Draft: Export the audit log as CSV", startedMinutesAgo: 9, estimateMinutes: 40),
        ]
    }

    var readings: [Checkout.ID: CheckoutReading] {
        [
            checkout(1).id: .read(CheckoutState(status: GitStatus(branch: "develop"), ahead: 0, behind: 3, localBaseBehind: 3)),
            checkout(2).id: .read(CheckoutState(
                status: GitStatus(branch: "1234-fix-login-timeout-for-sso-users"), ahead: 3, behind: 14, localBaseBehind: 20)),
            checkout(3).id: .read(CheckoutState(
                status: GitStatus(branch: "1302-export-audit-log-as-csv", changedFiles: 3, untrackedFiles: 1), ahead: 1,
                behind: 0, localBaseBehind: 8)),
            checkout(4).id: .read(CheckoutState(status: GitStatus(branch: "develop"), ahead: 0, behind: 674, localBaseBehind: 674)),
            checkout(5).id: .read(CheckoutState(
                status: GitStatus(branch: "1288-dark-mode-for-the-agent-console"), ahead: 5, behind: 2, localBaseBehind: 2)),
            checkout(6).id: .failed("git took longer than 20 s"),
        ]
    }

    /// develop2's and develop1's local branches without a merge request: one pushed and ahead, one not pushed, one whose
    /// remote branch is gone, and the one a task is on
    var branches: [Checkout.ID: LocalBranchesReading] {
        let list = [
            LocalBranch(
                name: "1301-rate-limit-the-export-api", upstream: "origin/1301-rate-limit-the-export-api", aheadOfUpstream: 2,
                behindUpstream: 0, aheadOfBase: 4, behindBase: 31, subject: "Add a token bucket to the export endpoint",
                committedAt: f.minutesAgo(26 * 60), isPushed: true),
            LocalBranch(
                name: "1277-try-new-retry-policy", aheadOfBase: 1, behindBase: 220, subject: "Spike: exponential backoff",
                committedAt: f.minutesAgo(9 * 24 * 60)),
            LocalBranch(
                name: "1190-remove-legacy-cache", upstream: "origin/1190-remove-legacy-cache", upstreamGone: true,
                aheadOfBase: 0, behindBase: 410, subject: "Remove the legacy cache", committedAt: f.minutesAgo(40 * 24 * 60)),
        ]
        let reading = LocalBranchesReading.read(LocalBranches(branches: list, total: 6, readAt: f.now))
        return [checkout(1).id: reading, checkout(2).id: reading]
    }

    func data(
        settings: RepositorySettings? = nil, findings: [FolderFindings]? = nil, readings: [Checkout.ID: CheckoutReading]? = nil,
        isRefreshing: Bool = false, refreshed: Bool = true, actionProblems: [Checkout.ID: String] = [:]
    ) -> WorkspacesData {
        WorkspacesData(
            settings: settings ?? RepositorySettings(folders: [folder], ideCommand: "code {path}"),
            findings: findings ?? [FolderFindings(folder: folder.id, checkouts: checkouts)],
            readings: readings ?? self.readings, isRefreshing: isRefreshing, lastRefreshAt: refreshed ? f.minutesAgo(2) : nil,
            actionProblems: actionProblems, branches: branches, gitLab: URL(string: "https://gitlab.example.com"),
            gitLabProject: "group/subgroup/project", mergeRequests: mergeRequests, workItems: [loginItem, darkModeItem], builds: builds,
            me: f.me, home: home, now: f.now)
    }
}

extension Fixtures {
    /// the fixtures of the Workspaces section
    var workspacesScreen: WorkspacesFixtures { WorkspacesFixtures(f: self) }
}

/// The whole main window with Workspaces selected, as the gallery shows it.
struct WorkspacesGalleryView: View {
    let fixtures: Fixtures
    let data: WorkspacesData
    var selection: Checkout.ID?
    var query = ""
    var size = MainWindowGalleryView<EmptyView, EmptyView>.defaultSize

    var body: some View {
        let list = WorkspacesListModel(data, query: query)
        MainWindowGalleryView(
            model: MainWindowShellModel(
                fixtures.mergeRequestsScreen.panel(), section: .workspaces, workspacesSubtitle: list.subtitle,
                workspacesBusy: data.isRefreshing),
            section: .workspaces, searchText: query, size: size
        ) {
            WorkspacesListContent(model: list, selection: .constant(selection), actions: .none)
        } detail: {
            WorkspaceDetailContent(
                row: list.row(selection), home: data.home, hasIDECommand: list.hasIDECommand, readAt: data.lastRefreshAt,
                now: data.now, startWorkItems: list.startWorkItems, actions: .none)
        }
    }
}

/// Settings → Repositories with fixed values.
private struct RepositoriesGalleryView: View {
    let settings: RepositorySettings
    let findings: [FolderFindings]
    var readings: [Checkout.ID: CheckoutReading] = [:]
    let home: URL
    let program: ProgramLookup

    var body: some View {
        RepositoriesSettingsForm(
            settings: .constant(settings), findings: findings, readings: readings, home: home, program: program)
            .settingsPaneFrame(estimate: 560)
    }
}

extension GalleryCatalog {
    /// The Workspaces section and Settings → Repositories.
    static var workspacesEntries: [GalleryEntry] {
        let size = MainWindowGalleryView<EmptyView, EmptyView>.defaultSize
        let pane = CGSize(width: SettingsMetrics.width, height: 560)
        return [
            GalleryEntry(screen: "workspaces", state: "typical", size: size) { f in
                let w = f.workspacesScreen
                return WorkspacesGalleryView(fixtures: f, data: w.data(), selection: w.checkout(2).id)
            },
            GalleryEntry(screen: "workspaces", state: "changed-unknown-item", size: size) { f in
                let w = f.workspacesScreen
                return WorkspacesGalleryView(fixtures: f, data: w.data(), selection: w.checkout(3).id)
            },
            GalleryEntry(screen: "workspaces", state: "free-stale-base", size: size) { f in
                let w = f.workspacesScreen
                return WorkspacesGalleryView(fixtures: f, data: w.data(), selection: w.checkout(4).id)
            },
            GalleryEntry(screen: "workspaces", state: "no-merge-request", size: size) { f in
                let w = f.workspacesScreen
                return WorkspacesGalleryView(fixtures: f, data: w.data(), selection: w.checkout(5).id)
            },
            GalleryEntry(screen: "workspaces", state: "unreadable", size: size) { f in
                let w = f.workspacesScreen
                return WorkspacesGalleryView(fixtures: f, data: w.data(), selection: w.checkout(6).id)
            },
            GalleryEntry(screen: "workspaces", state: "ide-failed", size: size) { f in
                let w = f.workspacesScreen
                let problems = [w.checkout(1).id: "devtool: no workspace named develop1"]
                return WorkspacesGalleryView(fixtures: f, data: w.data(actionProblems: problems), selection: w.checkout(1).id)
            },
            GalleryEntry(screen: "workspaces", state: "no-ide-command", size: size) { f in
                let w = f.workspacesScreen
                let settings = RepositorySettings(folders: [w.folder])
                return WorkspacesGalleryView(fixtures: f, data: w.data(settings: settings), selection: w.checkout(1).id)
            },
            GalleryEntry(screen: "workspaces", state: "free-start-work", size: size) { f in
                let w = f.workspacesScreen
                return WorkspacesGalleryView(fixtures: f, data: w.data(), selection: w.checkout(1).id)
            },
            GalleryEntry(screen: "workspaces", state: "search", size: size) { f in
                let w = f.workspacesScreen
                return WorkspacesGalleryView(fixtures: f, data: w.data(), selection: w.checkout(2).id, query: "login")
            },
            GalleryEntry(screen: "workspaces", state: "reading", size: size) { f in
                let w = f.workspacesScreen
                return WorkspacesGalleryView(
                    fixtures: f, data: w.data(findings: [], readings: [:], isRefreshing: true, refreshed: false))
            },
            GalleryEntry(screen: "workspaces", state: "no-repositories", size: size) { f in
                let w = f.workspacesScreen
                return WorkspacesGalleryView(
                    fixtures: f, data: w.data(settings: RepositorySettings(), findings: [], readings: [:]))
            },
            GalleryEntry(screen: "workspaces", state: "no-checkouts", size: size) { f in
                let w = f.workspacesScreen
                let findings = [FolderFindings(folder: w.folder.id, checkouts: [], problem: .noMatches)]
                return WorkspacesGalleryView(fixtures: f, data: w.data(findings: findings, readings: [:]))
            },
            GalleryEntry(screen: "settings-repositories", state: "typical", size: pane) { f in
                let w = f.workspacesScreen
                let single = RepositoryFolder(
                    id: UUID(uuidString: "0B6F8E31-2C4D-4E5A-8B7C-9D0E1F2A3B4C")!, path: "~/src/docs-site", baseBranch: "main")
                let settings = RepositorySettings(folders: [w.folder, single], ideCommand: "code {path}")
                let findings = [
                    FolderFindings(folder: w.folder.id, checkouts: w.checkouts),
                    FolderFindings(folder: single.id, checkouts: [
                        Checkout(path: "/Users/jdoe/src/docs-site", name: "docs-site", baseBranch: "main", folder: single.id),
                    ]),
                ]
                return RepositoriesGalleryView(
                    settings: settings, findings: findings, readings: w.readings, home: w.home,
                    program: .found("/opt/homebrew/bin/code"))
            },
            GalleryEntry(screen: "settings-repositories", state: "empty", size: pane) { f in
                RepositoriesGalleryView(
                    settings: RepositorySettings(), findings: [], home: f.workspacesScreen.home, program: .off)
            },
            GalleryEntry(screen: "settings-repositories", state: "problems", size: pane) { f in
                let w = f.workspacesScreen
                let typo = RepositoryFolder(
                    id: UUID(uuidString: "7A2B3C4D-5E6F-4A8B-9C0D-1E2F3A4B5C6D")!, path: "~/workspace/*/project")
                let plain = RepositoryFolder(
                    id: UUID(uuidString: "1F2E3D4C-5B6A-4978-8695-A4B3C2D1E0F9")!, path: "~/Documents")
                let settings = RepositorySettings(
                    folders: [typo, plain], ideCommand: "devtool open {name}")
                let findings = [
                    FolderFindings(folder: typo.id, checkouts: [], problem: .noMatches),
                    FolderFindings(folder: plain.id, checkouts: [], problem: .notACheckout),
                ]
                return RepositoriesGalleryView(
                    settings: settings, findings: findings, home: w.home, program: .notFound("devtool"))
            },
        ]
    }
}
#endif
