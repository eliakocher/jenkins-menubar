import AppKit
import MenubarCore
import Observation
import SwiftUI

/// The Watch a Build… sheet (Task 4.6, `docs/design/watch-sheet.md`): a link or `!123`, then Return watches it once
/// Jenkins confirms the job (WATCH-01 to WATCH-03).
///
/// ``MainWindowRoot`` presents it while ``WindowRouter/watchRequest`` is set.
/// - Each open starts clean: the request's text and reason, or a standing problem (no team values, no Jenkins token).
/// - A route while it is open focuses the field; a refusal route replaces the text and the status.
/// - Closing during a check lets the check finish: a success is applied, a refusal opens the sheet again with the text
///   and the reason (decision Q2).
/// - It reads the clipboard only with "Fill in a copied link" on (decision Q1).
public struct WatchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @ViewState private var session = WatchSession()

    public init() {}

    public var body: some View {
        @Bindable var session = session
        var content = WatchSheetContent(
            text: $session.text, selection: $session.selection, status: shownStatus, focusRequest: session.focusRequest,
            eggLine: session.eggLine, onWatch: watch, onClose: close, onOpenSettings: { router.open(.settings(pane: $0)) })
        if model.projects.hasSeveral {
            content.projects = model.projects.stores.map { ($0.projectID, model.projects.names[$0.projectID] ?? $0.project.shortName) }
            content.project = $session.project
        }
        return content
            .presentationSizing(.fitted)
            .onAppear {
                session.isOpen = true
                if let request = router.watchRequest {
                    session.apply(request)
                    session.requestID = request.id
                }
                if let project = router.watchRequest?.project {
                    session.project = project
                }
                fillInCopiedLink()
            }
            .onDisappear { session.isOpen = false }
            .onChange(of: session.text) {
                session.textChanged()
            }
            .onChange(of: router.watchRequest?.id) {
                guard let request = router.watchRequest, request.id != session.requestID else {
                    return
                }
                session.requestID = request.id
                if request.isRefusal {
                    session.apply(request)
                }
                session.focusRequest += 1
            }
    }

    /// The status, or the standing problem when there is nothing else to show: missing team values first, then no
    /// Jenkins token (`watch-sheet.md`, Standing problems).
    private var shownStatus: WatchStatus {
        guard session.status == .none, let problem = standingProblem else {
            return session.status
        }
        return WatchStatus(.problem(problem))
    }

    /// the store of the project the text is watched in: the one a link points into, else the chosen one
    private func store(for text: String) -> PipelinesStore {
        let projects = model.projects
        let chosen = projects.store(for: session.project) ?? projects.primary
        let id = WatchTarget.project(of: text, among: projects.stores.map(\.project), chosen: chosen.projectID)
        return projects.store(for: id) ?? chosen
    }

    private var standingProblem: Problem? {
        let pipelines = model.projects.store(for: session.project) ?? model.pipelines
        if !pipelines.project.team.missing.isEmpty {
            return .teamValuesMissing
        }
        return pipelines.checkProblem == .noToken(.jenkins) ? .noToken(.jenkins) : nil
    }

    private var eggsOn: Bool {
        model.pipelines.preferences.easterEggs
    }

    private func close() {
        router.watchRequest = nil
    }

    /// Watches the text: the checks that need no request answer at once, without a spinner; Jenkins' confirmation
    /// shows the spinner while it runs.
    private func watch() {
        let text = session.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !session.isChecking else {
            return
        }
        let pipelines = store(for: text)
        if let refusal = Self.localRefusal(text, pipelines: pipelines, standing: standingProblem) {
            session.show(WatchStatus(refusal))
            session.eggLine = eggsOn ? EggRules.watchRefusal(text) : nil
            return
        }
        session.isChecking = true
        session.status = .checking
        let session = session
        let router = router
        let model = model
        Task {
            let result = await pipelines.watch(text)
            session.isChecking = false
            if session.isOpen {
                session.show(WatchStatus(result))
                if case .success = result, pipelines.preferences.easterEggs {
                    session.eggLine = EggRules.fridayDeploy(now: model.dependencies.now())
                }
            } else if case .failure(let refusal) = result {
                var request = WatchRequest(text: text, refusal: refusal)
                request.project = pipelines.projectID
                router.open(.watch(request))
            }
        }
    }

    /// Returns why a text is refused without asking Jenkins: it isn't a link or a number of the team's, a standing
    /// problem refuses everything, or the job is one of mine (WATCH-02, WATCH-03).
    static func localRefusal(_ text: String, pipelines: PipelinesStore, standing: Problem?) -> WatchRefusal? {
        if let standing {
            return .problem(standing)
        }
        switch WatchTarget.parse(text, project: pipelines.project) {
        case .failure(let refusal):
            return refusal
        case .success(let job):
            return pipelines.state.myJobs?.contains(job) == true ? .mine(job: job) : nil
        }
    }

    /// With "Fill in a copied link" on, fills the empty field from the clipboard when it holds something to watch.
    private func fillInCopiedLink() {
        guard session.text.isEmpty, model.pipelines.preferences.fillInCopiedLink else {
            return
        }
        let watched = model.pipelines.userState.watched.map(\.job)
        let session = session
        Task {
            let suggestion = await ClipboardFill.suggestion(
                enabled: true, clipboard: SystemClipboard(), watchedJobs: watched)
            if let suggestion, session.text.isEmpty {
                session.text = suggestion
                session.selectAll()
            }
        }
    }
}

/// One presentation of the sheet: the text, its selection, the status and whether a check runs.
@Observable
@MainActor
final class WatchSession {
    var text = ""
    var selection: TextSelection?
    var status = WatchStatus.none
    /// the text a refusal is about; the refusal goes once the text changes (`watch-sheet.md`, Return, the check, and
    /// the outcome)
    private var refusedText: String?
    var isChecking = false
    /// whether the sheet shows, so a check that ends after it closed reopens it with a refusal
    var isOpen = false
    /// the request the sheet shows
    var requestID: UUID?
    var focusRequest = 0
    /// the easter egg line under the outcome (EGG-18); gone with the outcome
    var eggLine: String?
    /// the project a number is watched in (plan Phase 13)
    var project = ProjectID.main

    /// Shows a request: its text, all selected, and its reason as a refusal.
    func apply(_ request: WatchRequest) {
        text = request.text ?? ""
        if let refusal = request.refusal {
            status = WatchStatus(refusal)
        } else {
            status = request.reason.map { .refused(message: $0, pane: nil) } ?? .none
        }
        refusedText = status.keepsText ? text : nil
        selectAll()
        focusRequest += 1
    }

    /// Takes a refusal away once the text it was about changes; a success stays until the next Return.
    func textChanged() {
        guard let refusedText, text != refusedText else {
            return
        }
        self.refusedText = nil
        if status.keepsText {
            status = .none
            eggLine = nil
        }
    }

    /// Shows an outcome: a success and one of mine clear the field; a refusal keeps the text, all selected, so ⌘V
    /// replaces it. The focus goes back to the field.
    func show(_ outcome: WatchStatus) {
        status = outcome
        eggLine = nil
        if outcome.keepsText {
            refusedText = text
            selectAll()
        } else {
            refusedText = nil
            text = ""
            selection = nil
        }
        focusRequest += 1
    }

    func selectAll() {
        selection = text.isEmpty ? nil : TextSelection(range: text.startIndex..<text.endIndex)
    }
}

/// The clipboard as "Fill in a copied link" reads it.
@MainActor
protocol ClipboardReading {
    /// Returns whether the clipboard holds something like a link or a number, without asking the person.
    func holdsLinkOrNumber() async -> Bool
    /// Returns the clipboard's text, which may show macOS's prompt.
    func text() -> String?
}

/// Fills the Watch a Build… field from the clipboard (WATCH-01, decision Q1).
enum ClipboardFill {
    /// Returns the copied text to fill in. Nothing is read with the setting off; with it on, the clipboard's text is read
    /// only when it looks like a link or a number, so macOS asks only then.
    ///
    /// - Parameters:
    ///   - enabled: the setting "Fill in a copied link"
    ///   - clipboard: the clipboard
    ///   - watchedJobs: the jobs watched now; a link to one of them isn't filled in
    /// - Returns: the text, or `nil` to leave the field empty
    @MainActor
    static func suggestion(enabled: Bool, clipboard: any ClipboardReading, watchedJobs: [String]) async -> String? {
        guard enabled, await clipboard.holdsLinkOrNumber(), let text = clipboard.text() else {
            return nil
        }
        return WatchTarget.suggestion(fromClipboard: text, watchedJobs: watchedJobs)
    }
}

/// The general pasteboard. `detectedPatterns(for:)` asks nothing; `string(forType:)` may show macOS's prompt, and gives
/// `nil` when the person denies it.
@MainActor
struct SystemClipboard: ClipboardReading {
    func holdsLinkOrNumber() async -> Bool {
        let patterns = try? await NSPasteboard.general.detectedPatterns(for: [\.probableWebURL, \.number])
        return !(patterns ?? []).isEmpty
    }

    func text() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
