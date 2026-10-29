#if DEBUG
import MenubarCore
import SwiftUI

/// The details of a merge request (MR-06 to MR-08), made up: Sam Lee, Alex Kim and the others of the merge requests
/// fixtures, files of a made-up Swift app.
extension MergeRequestsFixtures {
    private func person(_ username: String) -> MergeRequest.Person {
        MergeRequest.Person(username: username, name: reviewer(username, .unreviewed).name)
    }

    private func job(_ id: Int, _ name: String, _ stage: String, _ state: MergeRequestDetails.Job.State) -> MergeRequestDetails.Job {
        MergeRequestDetails.Job(
            id: "gid://gitlab/Ci::Build/\(id)", name: name, stage: stage, state: state,
            url: URL(string: "https://gitlab.example.com/group/subgroup/project/-/jobs/\(id)"))
    }

    /// !16: one of two approvals with two rules, seven open threads (four on the diff), a failed pipeline with two
    /// failed jobs, one running and a long test stage
    var details16: MergeRequestDetails {
        let notes = "https://gitlab.example.com/group/subgroup/project/-/merge_requests/16#note_"
        func thread(_ id: Int, _ who: String, _ text: String, at location: String? = nil) -> MergeRequestDetails.ReviewThread {
            .init(id: "gid://gitlab/Discussion/\(id)", author: person(who), excerpt: text, location: location, url: URL(string: notes + "\(id)"))
        }
        return MergeRequestDetails(
            approvals: .init(
                approvedBy: [person("akim")], required: 2,
                rules: [
                    .init(name: "Code Owners", required: 1, approvedBy: [person("akim")], isSatisfied: true),
                    .init(name: "Backend Review", required: 1, approvedBy: [], isSatisfied: false),
                ]),
            threads: [
                thread(1, "slee", "Why not retry on the caller's side? The export job already knows its own timeout.", at: "Sources/Export/ExportJob.swift:42"),
                thread(2, "slee", "This swallows the error. Please log it, or the next person will search for an hour.", at: "Sources/Export/ExportJob.swift:77"),
                thread(3, "akim", "Could we name this `retryDelay`, so it matches the setting?", at: "Sources/Export/RetryPolicy.swift:9"),
                thread(4, "rmeyer", "Missing a test for the case where the second attempt fails as well.", at: "Tests/ExportTests/RetryTests.swift:120"),
                thread(5, "akim", "Do we want this in the release notes?"),
                thread(6, "cnovak", "The description says three attempts, the code makes five."),
                thread(7, "slee", "Nit: the comment above is out of date now.", at: "Sources/Export/ExportJob.swift:15"),
            ],
            resolvedThreadCount: 3,
            pipeline: MergeRequestDetails.Pipeline(
                status: .failed, url: URL(string: "https://gitlab.example.com/group/subgroup/project/-/pipelines/9001"),
                stages: [
                    .init(name: "build", jobs: [job(1, "compile", "build", .passed), job(2, "lint", "build", .passed)]),
                    .init(
                        name: "test",
                        jobs: [
                            job(3, "unit-tests", "test", .passed), job(4, "export-integration-tests", "test", .failed),
                            job(5, "ui-tests-light", "test", .passed), job(6, "ui-tests-dark", "test", .failed),
                            job(7, "snapshot-tests", "test", .running), job(8, "coverage", "test", .passed),
                        ]),
                    .init(name: "package", jobs: [job(9, "app-bundle", "package", .waiting)]),
                    .init(name: "deploy", jobs: [job(10, "publish-preview", "deploy", .waiting)]),
                ]))
    }

    /// !21 on a GitLab without approval rules: two people approved, every thread resolved, a pipeline that passed
    var details21: MergeRequestDetails {
        MergeRequestDetails(
            approvals: .init(approvedBy: [person("slee"), person("akim")], required: 2),
            resolvedThreadCount: 4,
            pipeline: MergeRequestDetails.Pipeline(
                status: .success, url: URL(string: "https://gitlab.example.com/group/subgroup/project/-/pipelines/8990"),
                stages: [
                    .init(name: "build", jobs: [job(21, "compile", "build", .passed), job(22, "lint", "build", .passed)]),
                    .init(name: "test", jobs: [job(23, "unit-tests", "test", .passed), job(24, "ui-tests", "test", .passed)]),
                    .init(name: "package", jobs: [job(25, "app-bundle", "package", .passed)]),
                ]))
    }

    /// !17: mine, six reviewers (MR-09, MR-10): Sam, Pat and Chris reviewed before newer commits, Alex approved after the
    /// last push, Kim's review has no time, Robin has not reviewed
    var mr17: MergeRequest {
        let slee = reviewer("slee", .reviewed)
        let akim = reviewer("akim", .approved)
        let rmeyer = reviewer("rmeyer", .unreviewed)
        let cnovak = reviewer("cnovak", .reviewed)
        let privera = reviewer("privera", .requestedChanges)
        let kweber = reviewer("kweber", .reviewed)
        return mergeRequest(
            17, "Retry the export when the connection drops", status: "NOT_APPROVED", pipeline: "SUCCESS",
            reviewers: [slee, akim, rmeyer, cnovak, privera, kweber], updatedMinutesAgo: 40)
    }

    /// The reviews of !17: pushed 50 and 40 minutes ago, after the reviews of Sam, Pat and Chris
    var reviews17: MergeRequestReviews {
        func who(_ number: Int, _ username: String, _ state: MergeRequest.ReviewState, minutesAgo: Double?) -> MergeRequestReviews.Reviewer {
            let name = reviewer(username, state).name
            return MergeRequestReviews.Reviewer(
                id: "gid://gitlab/User/\(number)", username: username, name: name, reviewState: state,
                reviewed: state != .unreviewed, approved: state == .approved, reviewedAt: minutesAgo.map(f.minutesAgo))
        }
        return MergeRequestReviews(
            reviewers: [
                who(11, "slee", .reviewed, minutesAgo: 180), who(12, "akim", .approved, minutesAgo: 20),
                who(13, "rmeyer", .unreviewed, minutesAgo: nil), who(14, "cnovak", .reviewed, minutesAgo: 45),
                who(15, "privera", .requestedChanges, minutesAgo: 120), who(16, "kweber", .reviewed, minutesAgo: nil),
            ],
            lastPushedAt: f.minutesAgo(40),
            commitDates: [f.minutesAgo(300), f.minutesAgo(50), f.minutesAgo(40)])
    }

    /// !17's details, with its reviews
    var details17: MergeRequestDetails {
        MergeRequestDetails(
            approvals: .init(approvedBy: [person("akim")], required: 2), resolvedThreadCount: 2,
            pipeline: details21.pipeline, reviews: reviews17)
    }
}

extension GalleryCatalog {
    /// The GitLab details of the merge request detail, tall enough for all of it.
    static var mergeRequestDetailsEntries: [GalleryEntry] {
        let size = CGSize(width: MainWindowGalleryView<EmptyView, EmptyView>.defaultSize.width, height: 1250)
        let reviewersSize = CGSize(width: size.width, height: 820)
        func entry(
            _ state: String, _ pick: @escaping @MainActor (MergeRequestsFixtures) -> (MergeRequest, MergeRequestDetailsState)
        ) -> GalleryEntry {
            GalleryEntry(screen: "merge-requests", state: state, size: size) { f in
                let m = f.mergeRequestsScreen
                let (selected, details) = pick(m)
                return MergeRequestsGalleryView(panel: m.panel(m.sections + [m.mr16]), selection: selected.id, size: size)
                    .environment(\.mergeRequestDetailsFixtures, MergeRequestDetailsFixtures(states: [selected.reference: details]))
            }
        }
        /// !17 with what the Reviewers section is doing about a re-request
        func reviewers(
            _ state: String, access: WriteAccess = .allowed, phase: ReReviewPhase? = nil
        ) -> GalleryEntry {
            GalleryEntry(screen: "merge-requests", state: state, size: reviewersSize) { f in
                let m = f.mergeRequestsScreen
                return MergeRequestsGalleryView(panel: m.panel(m.sections + [m.mr17]), selection: m.mr17.id, size: reviewersSize)
                    .environment(
                        \.mergeRequestDetailsFixtures,
                        MergeRequestDetailsFixtures(
                            states: [m.mr17.reference: .loaded(m.details17)], writeAccess: access, reReviewPhase: phase))
            }
        }
        let failed = ReReviewOutcome(
            sent: [.init(id: "gid://gitlab/User/11", username: "slee", name: "Sam Lee")],
            failures: [
                .init(reviewer: .init(id: "gid://gitlab/User/15", username: "privera", name: "Pat Rivera"),
                      message: "GitLab unreachable")
            ])
        return [
            reviewers("reviewers"),
            reviewers("reviewers-confirm", phase: .confirming),
            reviewers("reviewers-token", access: .readOnly, phase: .needsToken),
            reviewers("reviewers-failed", phase: .done(failed)),
            entry("details") { ($0.mr16, .loaded($0.details16)) },
            entry("details-no-rules") { ($0.mr21, .loaded($0.details21)) },
            entry("details-failed") { ($0.mr14, MergeRequestDetailsState(details: nil, isCurrent: false, failed: true)) },
        ]
    }
}
#endif
