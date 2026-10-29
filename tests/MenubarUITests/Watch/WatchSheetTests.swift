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

    @Test("WATCH-01 the sheet says what happened to the text")
    func outcomes() {
        let watched = WatchedJob(job: "MR-2", label: "!2", added: Date())
        #expect(WatchStatus(.success(.watching(watched, title: "Retry the upload"))) ==
            .watched(message: "Watching all builds of !2", title: "Retry the upload"))
        // The title is left out when it only repeats the label.
        #expect(WatchStatus(.success(.watching(watched, title: "!2"))) == .watched(message: "Watching all builds of !2", title: nil))
        #expect(WatchStatus(.success(.alreadyWatching(watched))) == .watched(message: "Already watching all builds of !2", title: nil))
        #expect(!WatchStatus(.success(.alreadyWatching(watched))).keepsText)
    }

    @Test("WATCH-03 does not watch my own job: the sheet says so and clears the field")
    func mine() {
        let status = WatchStatus(.mine(job: "MR-1"))
        #expect(status == .yours(message: "!1 is yours: it shows with your builds anyway"))
        #expect(!status.keepsText)
    }

    @Test("WATCH-02 refusals keep the text, and those a setting fixes link to it")
    func refusals() {
        #expect(WatchStatus(.notAMergeRequest) == .refused(message: "That GitLab link is not a merge request", pane: nil))
        #expect(WatchStatus(.notAMergeRequest).keepsText)
        #expect(WatchStatus(.problem(.noToken(.jenkins))) ==
            .refused(message: "No Jenkins token: add it in Settings → Accounts", pane: .accounts))
        #expect(WatchStatus(.problem(.rejectedToken(.jenkins))) == .refused(message: "Jenkins rejected the token", pane: .accounts))
        #expect(WatchStatus(.problem(.teamValuesMissing)) ==
            .refused(message: "Fill in the team settings: your Jenkins job and GitLab project", pane: .team))
        #expect(WatchStatus(.problem(.unreachable(.jenkins))) == .refused(message: "Jenkins unreachable (VPN?)", pane: nil))
        #expect(WatchStatus(.noJob(job: "MR-9")) == .refused(message: "Jenkins has no job !9", pane: nil))
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

    @Test("APP-03 a refused watch link opens the sheet with the refusal as Return would show it")
    func routedRefusal() {
        let session = WatchSession()
        session.apply(WatchRequest(text: "!1", refusal: .mine(job: "MR-1")))
        #expect(session.status == .yours(message: "!1 is yours: it shows with your builds anyway"))

        session.apply(WatchRequest(text: "!9", refusal: .problem(.rejectedToken(.jenkins))))
        #expect(session.text == "!9")
        #expect(session.status == .refused(message: "Jenkins rejected the token", pane: .accounts))

        // A request with a reason alone, as an older route sends it.
        session.apply(WatchRequest(text: "x", reason: "Paste a link to a Jenkins build or a GitLab merge request, or !123"))
        #expect(session.status == .refused(message: "Paste a link to a Jenkins build or a GitLab merge request, or !123", pane: nil))
        session.text = "y"
        session.textChanged()
        #expect(session.status == .none)
    }

    @Test("WATCH-02 the job URL of another Jenkins wraps as a whole")
    func unbrokenURL() {
        guard case .refused(let message, _) = WatchStatus(.otherJenkins(jobURL: "https://jenkins.example.com/job/project")) else {
            Issue.record("not a refusal")
            return
        }
        #expect(message.replacingOccurrences(of: "\u{2060}", with: "") ==
            "That is not a link into the Jenkins job in Team, https://jenkins.example.com/job/project")
        #expect(message.contains("https:\u{2060}/\u{2060}/\u{2060}"))
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
