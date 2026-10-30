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

    /// !16: one of two approvals with four rules (two open), seven open threads (four on the diff), a failed pipeline with two
    /// failed jobs, one running and a long test stage
    var details16: MergeRequestDetails {
        let notes = "https://gitlab.example.com/group/subgroup/project/-/merge_requests/16#note_"
        func reply(_ id: Int, _ who: String, _ minutesAgo: Double, _ text: String) -> ThreadNote {
            ThreadNote(
                id: "gid://gitlab/DiffNote/\(id)", author: person(who), body: text,
                createdAt: Date.now.addingTimeInterval(-minutesAgo * 60), url: URL(string: notes + "\(id)"))
        }
        func thread(
            _ id: Int, _ who: String, _ text: String, at location: String? = nil, replies: [ThreadNote] = []
        ) -> MergeRequestDetails.ReviewThread {
            .init(
                id: "gid://gitlab/Discussion/\(id)", author: person(who), excerpt: text, location: location,
                url: URL(string: notes + "\(id)"), body: text, createdAt: Date.now.addingTimeInterval(-3 * 3600), replies: replies)
        }
        return MergeRequestDetails(
            approvals: .init(
                approvedBy: [person("akim")], required: 2,
                // Code owner rules named by their pattern, repeated by a second CODEOWNERS section, and "*".
                rules: [
                    .init(name: "*", required: 1, approvedBy: [person("akim")], isSatisfied: true),
                    .init(name: "*.swift", required: 1, approvedBy: [person("akim")], isSatisfied: true),
                    .init(name: "Backend Review", required: 1, approvedBy: [], isSatisfied: false),
                    .init(name: "*.swift", required: 1, approvedBy: [person("akim")], isSatisfied: true),
                    .init(name: "Sources/Export/", required: 1, approvedBy: [], isSatisfied: false),
                    .init(name: "Optional Design Look", required: 0, isSatisfied: true),
                ]),
            threads: [
                thread(1, "slee", "Why not retry on the caller's side? The export job already knows its own timeout.", at: "Sources/Export/ExportJob.swift:42", replies: [
                    reply(101, "akim", 150, "It does, but the retry belongs next to the **timeout**, see `RetryPolicy`."),
                    reply(102, "slee", 100, "Fair. Then the caller needs to know about the attempts."),
                    reply(103, "akim", 60, "Added `attempts` to the job's result."),
                    reply(104, "slee", 20, "Thanks, that works for me."),
                ]),
                thread(2, "slee", "This swallows the error. Please log it, or the next person will search for an hour.", at: "Sources/Export/ExportJob.swift:77", replies: [
                    reply(105, "rmeyer", 30, "Logged now, with the job's id.")]),
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

extension MergeRequestsFixtures {
    /// !16's changes (MR-11): a Swift file with two hunks and a line without a newline at its end, a new file, a rename,
    /// a deleted file, an image, a lockfile GitLab collapsed, and a big generated file that starts folded
    var changes16: MergeRequestChanges {
        func file(
            _ path: String, _ kind: MergeRequestChanges.FileChange.Kind, old: String? = nil, diff: String
        ) -> MergeRequestChanges.FileChange {
            MergeRequestChanges.FileChange(
                oldPath: old ?? path, newPath: path, kind: kind, isGenerated: GeneratedFiles.isGenerated(path),
                content: UnifiedDiff.parse(diff))
        }
        let job = """
            @@ -38,9 +38,14 @@ final class ExportJob {
                 func run() async throws {
                     let batch = try await store.nextBatch()
            -        try await uploader.upload(batch)
            +        try await RetryPolicy.standard.run {
            +            try await uploader.upload(batch)
            +        }
                     log.info("Exported \\(batch.count) items")
                 }

            -    private let timeout: Duration = .seconds(30)
            +    /// the time one attempt may take; the policy decides how many attempts follow
            +    private let timeout: Duration = .seconds(20)
            +    private let policy = RetryPolicy.standard
             }
            @@ -120,3 +125,3 @@ extension ExportJob {
                 static let name = "export"
            -    static let version = 2
            +    static let version = 3
            \\ No newline at end of file

            """
        let policy = """
            @@ -0,0 +1,12 @@
            +/// How often and how long an export retries when the connection drops.
            +struct RetryPolicy: Sendable {
            +    var attempts: Int
            +    var delay: Duration
            +
            +    static let standard = RetryPolicy(attempts: 3, delay: .seconds(2))
            +
            +    func run<T>(_ body: () async throws -> T) async throws -> T {
            +        try await body()
            +    }
            +}
            +

            """
        let generated = "@@ -1,0 +1,600 @@\n" + (1...600).map { "+  \"entry-\($0)\": \"\($0)\"," }.joined(separator: "\n")
        return MergeRequestChanges(files: [
            file("Sources/Export/ExportJob.swift", .modified, diff: job),
            file("Sources/Export/RetryPolicy.swift", .added, diff: policy),
            file("Sources/Export/Uploader.swift", .renamed, old: "Sources/Export/Upload.swift", diff: ""),
            file("Sources/Export/LegacyExport.swift", .deleted, diff: "@@ -1,3 +0,0 @@\n-// The old export, before the retry.\n-enum LegacyExport {\n-}\n"),
            file("Resources/export-icon.png", .modified, diff: "Binary files a/Resources/export-icon.png and b/Resources/export-icon.png differ\n"),
            MergeRequestChanges.FileChange(
                oldPath: "package-lock.json", newPath: "package-lock.json", kind: .modified, isGenerated: true, content: .notShown),
            file("Resources/strings.generated.json", .modified, diff: generated),
        ])
    }
}

extension MergeRequestsFixtures {
    /// the folders of ``changesLarge``
    static let largeFolders = [
        "Sources/Export/", "Sources/Export/Formats/", "Sources/Import/", "Sources/Sync/", "Sources/Sync/Conflicts/",
        "Sources/Storage/", "Sources/Storage/Migrations/", "Sources/UI/Settings/", "Sources/UI/Timeline/",
        "Tests/ExportTests/", "Tests/ImportTests/", "Tests/SyncTests/", "Resources/Localizable/", "docs/api/",
        "web/src/components/", "web/src/pages/",
    ]

    /// A merge request of 1,200 files (MR-11), made up in code rather than a fixture file: GitLab's list of paths with
    /// their +/−, the first page of diffs loaded (their kinds known), the rest waiting for their pages, a few generated
    /// files among them.
    var changesLarge: MergeRequestChanges {
        let folders = Self.largeFolders
        var files: [MergeRequestChanges.FileChange] = []
        for index in 0..<1200 {
            let folder = folders[index * folders.count / 1200]
            let name = index % 97 == 5 ? "Strings\(index).generated.json" : "File\(String(format: "%04d", index)).swift"
            let path = folder + name
            let additions = (index * 37) % 90 + 1
            let deletions = (index * 11) % 23
            files.append(
                MergeRequestChanges.FileChange(
                    oldPath: path, newPath: path, kind: nil, isGenerated: GeneratedFiles.isGenerated(path), content: .notLoaded,
                    additions: additions, deletions: deletions))
        }
        // The first page came: its diffs, by path.
        let page = files.prefix(ChangesPaging.pageSize).enumerated().map { offset, file in
            let added = (1...3).map { "+    let value\($0) = \(offset * 10 + $0)" }.joined(separator: "\n")
            return MergeRequestChanges.FileChange(
                oldPath: file.oldPath, newPath: file.newPath, kind: offset % 6 == 0 ? .added : .modified,
                isGenerated: file.isGenerated,
                content: UnifiedDiff.parse("@@ -10,2 +10,4 @@ struct Export\(offset) {\n     func run() {\n-        old()\n\(added)\n"))
        }
        var changes = MergeRequestChanges(files: files)
        changes.merge(Array(page))
        return changes
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
        /// The Changes card of !16 in a layout, from a defaults suite of its own, so the user's choice doesn't leak in.
        func changes(
            _ state: String, layout: DiffLayoutChoice, width: CGFloat, unfoldedFolders: Set<String> = [],
            pick: @escaping @MainActor (MergeRequestsFixtures) -> MergeRequestChanges = { $0.changes16 }
        ) -> GalleryEntry {
            GalleryEntry(screen: "merge-requests", state: state, size: CGSize(width: width, height: 1150)) { f in
                let m = f.mergeRequestsScreen
                let defaults = UserDefaults(suiteName: "gallery.merge-requests.\(state)") ?? .standard
                defaults.set(layout.rawValue, forKey: "mergeRequestDiffLayout")
                return ScrollView {
                    ChangesCard(
                        mergeRequest: m.mr16, changesURL: m.mr16.webURL.appending(path: "diffs"), actions: .none,
                        unfoldedFolders: unfoldedFolders)
                        .padding(20)
                }
                .defaultAppStorage(defaults)
                .environment(
                    \.mergeRequestDetailsFixtures,
                    MergeRequestDetailsFixtures(states: [:], changes: [m.mr16.reference: .loaded(pick(m))]))
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
            // The Changes card alone, at the detail's width: it sits below the other cards. Inline, then side by side.
            changes("changes", layout: .inline, width: 640),
            changes("changes-split", layout: .sideBySide, width: 1000),
            // 1,200 files: the filter, the folders folded but the first, its files with their page of diffs come.
            changes(
                "changes-large", layout: .inline, width: 640, unfoldedFolders: [MergeRequestsFixtures.largeFolders[0]],
                pick: { $0.changesLarge }),
            entry("details-no-rules") { ($0.mr21, .loaded($0.details21)) },
            entry("details-failed") { ($0.mr14, MergeRequestDetailsState(details: nil, isCurrent: false, failed: true)) },
        ]
    }
}
#endif
