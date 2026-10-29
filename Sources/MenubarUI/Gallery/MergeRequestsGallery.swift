#if DEBUG
import MenubarCore
import SwiftUI

/// The whole main window with Merge Requests selected, as the gallery shows it: the shell from fixtures, the list and
/// the selected MR's detail.
struct MergeRequestsGalleryView: View {
    let panel: PanelData
    var selection: MergeRequest.ID?
    var query = ""
    var size = MainWindowGalleryView<EmptyView, EmptyView>.defaultSize

    var body: some View {
        let data = MergeRequestsData(panel)
        MainWindowGalleryView(
            model: MainWindowShellModel(panel, section: .mergeRequests), section: .mergeRequests, searchText: query, size: size
        ) {
            MergeRequestsListContent(model: MergeRequestsListModel(data, query: query), selection: .constant(selection), actions: .none)
        } detail: {
            MergeRequestDetailContent(model: MergeRequestDetailModel(data, selection: selection), actions: .none)
        }
    }
}

extension GalleryCatalog {
    /// One entry per state of `docs/design/merge-requests.md`.
    static var mergeRequestsEntries: [GalleryEntry] {
        let size = MainWindowGalleryView<EmptyView, EmptyView>.defaultSize
        let minimum = MainWindowGalleryView<EmptyView, EmptyView>.minimumSize
        // The least width, tall enough for the whole detail: the reviewers and the links (MERGE-REQUESTS-04).
        let tall = CGSize(width: minimum.width, height: 1000)
        return [
            GalleryEntry(screen: "merge-requests", state: "sections", size: size) { f in
                let m = f.mergeRequestsScreen
                return MergeRequestsGalleryView(panel: m.panel(), selection: m.web8.id)
            },
            GalleryEntry(screen: "merge-requests", state: "badges", size: size) { f in
                let m = f.mergeRequestsScreen
                return MergeRequestsGalleryView(panel: m.panel(m.badges), selection: m.mr18.id)
            },
            GalleryEntry(screen: "merge-requests", state: "badges-more", size: size) { f in
                let m = f.mergeRequestsScreen
                return MergeRequestsGalleryView(panel: m.panel(m.badgesMore), selection: m.badgesMore[4].id)
            },
            GalleryEntry(screen: "merge-requests", state: "detail-reviewers", size: size) { f in
                let m = f.mergeRequestsScreen
                return MergeRequestsGalleryView(panel: m.panel(m.sections + [m.mr16AllReviewers]), selection: m.mr16.id)
            },
            GalleryEntry(screen: "merge-requests", state: "detail-review-requested", size: size) { f in
                let m = f.mergeRequestsScreen
                let build = m.build(of: m.mr14, number: 3, phase: .running, kind: .watched)
                return MergeRequestsGalleryView(panel: m.panel(builds: [build]), selection: m.mr14.id)
            },
            GalleryEntry(screen: "merge-requests", state: "jenkins-build", size: size) { f in
                let m = f.mergeRequestsScreen
                let build = m.build(of: m.mr16, number: 3, phase: .finished(result: .failure, duration: 12 * 60))
                return MergeRequestsGalleryView(panel: m.panel(m.badgesWith(sixth: m.mr16), builds: [build]), selection: m.mr16.id)
            },
            GalleryEntry(screen: "merge-requests", state: "detail-no-pipeline", size: size) { f in
                let m = f.mergeRequestsScreen
                return MergeRequestsGalleryView(panel: m.panel(m.badges), selection: m.mr25.id)
            },
            GalleryEntry(screen: "merge-requests", state: "empty", size: size) { f in
                MergeRequestsGalleryView(panel: f.mergeRequestsScreen.panel([]))
            },
            GalleryEntry(screen: "merge-requests", state: "no-token", size: size) { f in
                MergeRequestsGalleryView(panel: f.mergeRequestsScreen.panel(problem: .noToken(.gitLab), loaded: false))
            },
            GalleryEntry(screen: "merge-requests", state: "gitlab-problem", size: size) { f in
                MergeRequestsGalleryView(panel: f.mergeRequestsScreen.panel(problem: .unreachable(.gitLab), loaded: false))
            },
            GalleryEntry(screen: "merge-requests", state: "gitlab-problem-cached", size: size) { f in
                let m = f.mergeRequestsScreen
                return MergeRequestsGalleryView(panel: m.panel(problem: .rejectedToken(.gitLab)), selection: m.mr21.id)
            },
            GalleryEntry(screen: "merge-requests", state: "loading", size: size) { f in
                MergeRequestsGalleryView(panel: f.mergeRequestsScreen.panel(isLoading: true, loaded: false))
            },
            GalleryEntry(screen: "merge-requests", state: "loading-cached", size: size) { f in
                MergeRequestsGalleryView(panel: f.mergeRequestsScreen.panel(isLoading: true))
            },
            GalleryEntry(screen: "merge-requests", state: "offline", size: size) { f in
                let m = f.mergeRequestsScreen
                return MergeRequestsGalleryView(panel: m.panel(jenkinsProblem: .offline), selection: m.mr14.id)
            },
            GalleryEntry(screen: "merge-requests", state: "no-team-values", size: size) { f in
                MergeRequestsGalleryView(panel: f.mergeRequestsScreen.panel(jenkinsProblem: .teamValuesMissing, team: TeamValues()))
            },
            GalleryEntry(screen: "merge-requests", state: "search-results", size: size) { f in
                let m = f.mergeRequestsScreen
                let mr29 = m.mergeRequest(29, "Fix the color contrast of the badges", status: "NOT_APPROVED",
                                          reviewers: [m.reviewer("akim", .reviewStarted)], updatedMinutesAgo: 50)
                return MergeRequestsGalleryView(panel: m.panel(m.sections + [mr29]), query: "color")
            },
            GalleryEntry(screen: "merge-requests", state: "search-no-results", size: size) { f in
                MergeRequestsGalleryView(panel: f.mergeRequestsScreen.panel(), query: "zzz")
            },
            GalleryEntry(screen: "merge-requests", state: "many-items", size: size) { f in
                let m = f.mergeRequestsScreen
                let many = m.many
                return MergeRequestsGalleryView(panel: m.panel(many), selection: many[20].id)
            },
            GalleryEntry(screen: "merge-requests", state: "long-titles", size: tall) { f in
                let m = f.mergeRequestsScreen
                let selected = m.longTitles[1]
                let build = m.build(of: selected, number: 12, phase: .finished(result: .unstable, duration: 25 * 60), kind: .watched)
                var team = f.team
                team.gitLabProject = m.longProject
                return MergeRequestsGalleryView(
                    panel: m.panel(m.longTitles, builds: [build], team: team), selection: selected.id, size: tall)
            },
            // The description (WIN-02) after the reviewers, cut after about 20 lines with Show More; tall enough to show
            // the cut and the links under it.
            GalleryEntry(screen: "merge-requests", state: "description", size: CGSize(width: size.width, height: 1150)) { f in
                let m = f.mergeRequestsScreen
                return MergeRequestsGalleryView(
                    panel: m.panel(), selection: m.mr14.id, size: CGSize(width: size.width, height: 1150))
                    .environment(\.descriptionFixtures, DescriptionFixtures(descriptions: [m.mr14.reference: .loaded(m.description14)]))
            },
        ]
    }
}
#endif
