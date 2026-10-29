#if DEBUG
import MenubarCore
import SwiftUI

/// The sheet's content as the gallery shows it, with a fixed text, selection and status.
struct WatchSheetGalleryView: View {
    var text = ""
    var selected = false
    var status = WatchStatus.none
    var eggLine: String?

    var body: some View {
        WatchSheetContent(
            text: .constant(text),
            selection: .constant(selected ? TextSelection(range: text.startIndex..<text.endIndex) : TextSelection(insertionPoint: text.endIndex)),
            status: status, eggLine: eggLine, onWatch: {}, onClose: {}, onOpenSettings: { _ in })
    }
}

extension GalleryCatalog {
    /// One entry per state of `docs/design/watch-sheet.md`; the heights fit the content.
    static var watchSheetEntries: [GalleryEntry] {
        func size(_ height: CGFloat) -> CGSize { CGSize(width: 480, height: height) }
        let consoleLink = "https://jenkins.example.com/job/project/job/MR-2/14/console"
        let longLink = "https://jenkins.example.com/job/project/job/"
            + "feature%252Fa-very-long-branch-name-that-moves-the-settings-import-to-the-new-file-format/12/console"
        return [
            GalleryEntry(screen: "watch-sheet", state: "empty", size: size(260)) { _ in
                WatchSheetGalleryView()
            },
            GalleryEntry(screen: "watch-sheet", state: "typed", size: size(260)) { _ in
                WatchSheetGalleryView(text: "!123")
            },
            GalleryEntry(screen: "watch-sheet", state: "pasted-link", size: size(260)) { _ in
                WatchSheetGalleryView(text: consoleLink)
            },
            GalleryEntry(screen: "watch-sheet", state: "checking", size: size(260)) { _ in
                WatchSheetGalleryView(text: consoleLink, status: .checking)
            },
            GalleryEntry(screen: "watch-sheet", state: "success", size: size(260)) { _ in
                WatchSheetGalleryView(status: .watched(
                    message: "Watching all builds of !2", title: "Retry the upload when the connection drops"))
            },
            GalleryEntry(screen: "watch-sheet", state: "success-egg-line", size: size(284)) { _ in
                WatchSheetGalleryView(
                    status: .watched(message: "Watching all builds of !2", title: "Retry the upload when the connection drops"),
                    eggLine: "Deploying on a Friday? Bold.")
            },
            GalleryEntry(screen: "watch-sheet", state: "own-job", size: size(260)) { _ in
                WatchSheetGalleryView(status: WatchStatus(.mine(job: "MR-1")))
            },
            GalleryEntry(screen: "watch-sheet", state: "refused", size: size(260)) { _ in
                WatchSheetGalleryView(
                    text: "https://gitlab.example.com/group/subgroup/project/-/pipelines/4711", selected: true,
                    status: WatchStatus(.notAMergeRequest))
            },
            GalleryEntry(screen: "watch-sheet", state: "from-link-refused", size: size(260)) { _ in
                WatchSheetGalleryView(
                    text: "https://ci.other.example.com/job/web/job/MR-7/3/", selected: true,
                    status: WatchStatus(.otherJenkins(jobURL: "https://jenkins.example.com/job/project")))
            },
            GalleryEntry(screen: "watch-sheet", state: "no-token", size: size(260)) { _ in
                WatchSheetGalleryView(status: WatchStatus(.problem(.noToken(.jenkins))))
            },
            GalleryEntry(screen: "watch-sheet", state: "no-team-values", size: size(260)) { _ in
                WatchSheetGalleryView(status: WatchStatus(.problem(.teamValuesMissing)))
            },
            GalleryEntry(screen: "watch-sheet", state: "long-link", size: size(260)) { _ in
                WatchSheetGalleryView(text: longLink)
            },
            GalleryEntry(screen: "watch-sheet", state: "long-label", size: size(280)) { _ in
                WatchSheetGalleryView(status: .watched(
                    message: "Watching all builds of feature/a-very-long-branch-name-that-moves-the-settings-import-to-the-new-file-format",
                    title: "Settings import: move to the new file format"))
            },
        ]
    }
}
#endif
