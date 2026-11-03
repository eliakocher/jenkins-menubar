#if DEBUG
import Foundation
import MenubarCore
import SwiftUI

/// The sidebar with several opened items, to see the two-line rows (WIN-06): work items with and without a known MR, MRs
/// with a leading "#123" or "Draft: #123", a build of an MR and one of a branch, a pinned item and a selected one. All
/// made up.
struct OpenedRowsGalleryView: View {
    let fixtures: Fixtures
    /// the index of the selected item
    var selected: Int
    var size: CGSize

    private struct Entry {
        var item: OpenedItem
        var mergeRequest: MergeRequest?
        var workItem: WorkItem?
        var related: RelatedMergeRequestsCache.Entry?
        var build: Build?
    }

    private var entries: [Entry] {
        let f = fixtures
        let w = f.workItemsScreen
        let project = "group/subgroup/project"
        func url(_ path: String) -> URL { URL(string: "https://gitlab.example.com/\(project)/-/\(path)")! }
        func opened(_ kind: OpenedItem.Kind, _ iid: Int, _ title: String?, pinned: Bool = false, job: String? = nil) -> OpenedItem {
            OpenedItem(
                kind: kind, project: project, iid: iid, webURL: url("x/\(iid)"), title: title, openedAt: f.minutesAgo(30),
                isPinned: pinned, job: job)
        }
        let item31 = w.item31
        let own = w.related(14, "Rework the color tokens", .opened, branch: "31-rework-the-color-tokens")
        let other = w.related(11, "Move the color values into one file", .merged, branch: "9-color-values")
        let failed = Build(
            job: "MR-14", number: 3, title: "Rework the color tokens", kind: .mine,
            phase: .finished(result: .failure, duration: 600), startedAt: f.minutesAgo(20))
        let running = Build(
            job: "release%252F2.4", number: 118, title: "Release 2.4 candidate", kind: .watched, phase: .running,
            startedAt: f.minutesAgo(4), estimatedDuration: 20 * 60)
        return [
            Entry(
                item: opened(.workItem, 31, item31.displayTitle), workItem: item31,
                related: RelatedMergeRequestsCache.Entry(workItemUpdatedAt: f.now, fetchedAt: f.now, mergeRequests: [own, other])),
            Entry(
                item: opened(.workItem, 19162, "Dialog bot answers twice when the visitor reloads the page"),
                workItem: w.item(19162, "Dialog bot answers twice when the visitor reloads the page")),
            Entry(
                item: opened(.mergeRequest, 12321, "#15327 Add the target to the export dialog"),
                mergeRequest: f.mergeRequest(12321, "#15327 Add the target to the export dialog")),
            Entry(
                item: opened(.mergeRequest, 88, "Draft: #15327 Retry the upload when the connection drops", pinned: true),
                mergeRequest: f.mergeRequest(88, "Draft: #15327 Retry the upload when the connection drops", draft: true)),
            Entry(
                item: opened(
                    .mergeRequest, 204, "#204: Speed up the search index rebuild for the very long running nightly jobs on big repositories"),
                mergeRequest: f.mergeRequest(204, "#204: Speed up the search index rebuild")),
            Entry(item: opened(.build, 3, "Rework the color tokens", job: "MR-14"), build: failed),
            Entry(item: opened(.build, 118, "Release 2.4 candidate", pinned: true, job: "release%252F2.4"), build: running),
            Entry(item: opened(.mergeRequest, 7, nil)),
        ]
    }

    var body: some View {
        let entries = entries
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.item.id, $0) })
        MainWindowSidebar(
            section: .constant(.pipelines),
            opened: OpenedSidebar(
                items: entries.map(\.item), selection: .constant(entries[selected].item.id),
                details: { item in
                    let entry = byID[item.id]
                    return OpenedItemRowDetails.make(
                        item: item, workItem: entry?.workItem, related: entry?.related,
                        build: entry?.build)
                })
        )
        .frame(width: size.width, height: size.height)
    }
}

extension GalleryCatalog {
    /// the sidebar's "Opened" rows, with a merge request selected and with a work item selected
    static var openedRowsEntries: [GalleryEntry] {
        let size = CGSize(width: 270, height: 640)
        return [
            GalleryEntry(screen: "main-window", state: "opened-rows", size: size) { f in
                OpenedRowsGalleryView(fixtures: f, selected: 3, size: size)
            },
            GalleryEntry(screen: "main-window", state: "opened-rows-selected-work-item", size: size) { f in
                OpenedRowsGalleryView(fixtures: f, selected: 0, size: size)
            },
        ]
    }
}
#endif
