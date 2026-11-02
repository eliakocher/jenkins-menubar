import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("WatchSheet")
@MainActor
struct WatchSheetTests {
    /// A clipboard that records whether it was read.
    @MainActor
    private final class Clipboard: ClipboardReading {
        var contents: String?
        var looksLikeLink: Bool
        private(set) var reads = 0

        init(_ contents: String?, looksLikeLink: Bool = true) {
            self.contents = contents
            self.looksLikeLink = looksLikeLink
        }

        func holdsLinkOrNumber() async -> Bool {
            looksLikeLink
        }

        func text() -> String? {
            reads += 1
            return contents
        }
    }

    @Test("WATCH-01 fills in a copied link only when the setting is on")
    func clipboardFill() async {
        let link = "  https://jenkins.example.com/job/project/job/MR-2/14/console "

        let off = Clipboard(link)
        #expect(await ClipboardFill.suggestion(enabled: false, clipboard: off, watchedJobs: []) == nil)
        // With the setting off, the clipboard isn't read at all, so macOS never asks.
        #expect(off.reads == 0)

        let on = Clipboard(link)
        #expect(await ClipboardFill.suggestion(enabled: true, clipboard: on, watchedJobs: []) == link.trimmingCharacters(in: .whitespaces))
        #expect(on.reads == 1)

        // Nothing that looks like a link or a number: not read either.
        let words = Clipboard("lunch at noon", looksLikeLink: false)
        #expect(await ClipboardFill.suggestion(enabled: true, clipboard: words, watchedJobs: []) == nil)
        #expect(words.reads == 0)

        // A number, and a link to a job watched already.
        #expect(await ClipboardFill.suggestion(enabled: true, clipboard: Clipboard("!123"), watchedJobs: []) == "!123")
        #expect(await ClipboardFill.suggestion(enabled: true, clipboard: Clipboard(link), watchedJobs: ["MR-2"]) == nil)
        // Denied: macOS gives no text.
        #expect(await ClipboardFill.suggestion(enabled: true, clipboard: Clipboard(nil), watchedJobs: []) == nil)
    }

    @Test("WATCH-02 a refusal stays until the text changes; a success until the next Return")
    func refusalClearsOnEdit() {
        let session = WatchSession()
        session.text = "https://gitlab.example.com/group/subgroup/project/-/pipelines/4711"
        session.show(WatchStatus(.notAMergeRequest))
        #expect(session.status == WatchStatus(.notAMergeRequest))
        #expect(session.text.hasSuffix("4711"))
        #expect(session.selection != nil)

        session.textChanged()
        #expect(session.status == WatchStatus(.notAMergeRequest))
        session.text = "!2"
        session.textChanged()
        #expect(session.status == .none)

        session.show(.watched(message: "Watching all builds of !2", title: nil))
        #expect(session.text.isEmpty)
        session.text = "!3"
        session.textChanged()
        #expect(session.status == .watched(message: "Watching all builds of !2", title: nil))
    }

    @Test("APP-03 routes a watch link: a refusal replaces the text and the reason of the open sheet")
    func watchRoute() {
        var opened: [WindowRoute] = []
        let router = WindowRouter { opened.append($0) }
        let request = WatchRequest(text: "https://ci.other.example.com/job/web/", reason: "That is not a link into the Jenkins job in Team")
        router.open(.watch(request))
        // The request is stored before the window opens, so the sheet shows as soon as the window appears.
        #expect(router.watchRequest == request)
        #expect(opened == [.watch(request)])
        #expect(request.isRefusal)
        #expect(!WatchRequest().isRefusal)

        router.open(.settings(pane: .accounts))
        #expect(router.watchRequest == request)
        #expect(opened.last == .settings(pane: .accounts))
    }
}
