import AppKit
import MenubarCore
import SwiftUI

/// What the Merge Requests and Work Items sections do outside themselves: open a page, copy a link, open Settings,
/// check now, and switch to a row of another section ("Show in …", `docs/design/main-window.md`). The public views
/// build them from the app; the gallery passes ``none``.
struct GitLabSectionActions {
    /// opens a web page: an MR, a work item, a link row
    var open: @MainActor (URL) -> Void
    /// puts a link on the clipboard
    var copy: @MainActor (URL) -> Void
    /// opens Settings at a pane
    var openSettings: @MainActor (SettingsPane) -> Void
    /// a Jenkins check and a GitLab reload (PIPE-07), MR-04's step 3
    var checkNow: @MainActor () -> Void
    /// selects a build in Pipelines, by its job: the MR detail's "Show in Pipelines"
    var showInPipelines: @MainActor (String) -> Void
    /// selects an MR in Merge Requests, by its web URL: a related MR's "Show in Merge Requests"
    var showInMergeRequests: @MainActor (MergeRequest.ID) -> Void
    /// switches the window's section, as Work Items' "Show Merge Requests" does without a GitLab token (MR-04)
    var showSection: @MainActor (MainWindowSection) -> Void
    /// watches the builds of an MR, by its number, in one click (WATCH-01)
    var watchBuilds: @MainActor (MergeRequest) -> Void = { _ in }
    /// opens GitLab's new issue page for "New Follow-Up Item" (NEW-04); `nil` while the team values can't make a link
    var newWorkItem: (@MainActor (NewWorkItemSource) -> Void)?

    /// actions that do nothing, for the gallery
    static var none: GitLabSectionActions {
        GitLabSectionActions(
            open: { _ in }, copy: { _ in }, openSettings: { _ in }, checkNow: {}, showInPipelines: { _ in },
            showInMergeRequests: { _ in }, showSection: { _ in })
    }

    /// Returns the app's actions.
    ///
    /// - Parameters:
    ///   - model: the app's model, for Check Now
    ///   - router: the window router, for Settings and the section switches
    ///   - openURL: the environment's action that opens web pages
    /// - Returns: the actions
    @MainActor
    static func live(model: AppModel, router: WindowRouter, openURL: OpenURLAction) -> GitLabSectionActions {
        GitLabSectionActions(
            open: { openURL($0) },
            copy: { url in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            },
            openSettings: { router.open(.settings(pane: $0)) },
            checkNow: { model.checkNow() },
            showInPipelines: { router.showInPipelines(job: $0) },
            showInMergeRequests: { router.showInMergeRequests($0) },
            showSection: { router.section = $0 },
            watchBuilds: { MergeRequestWatching.watch($0, model: model, router: router) },
            newWorkItem: NewWorkItemLauncher.action(model: model) { openURL($0) })
    }
}

/// Two rows standing in for a list that never loaded (OD-01): placeholders without a header and without shimmer
/// (`docs/design/main-window.md`, "Never loaded").
struct SectionPlaceholderRows: View {
    var body: some View {
        ForEach(0..<2, id: \.self) { index in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "circle.fill")
                    .frame(width: SectionRowMetrics.symbolColumn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: index == 0 ? "A placeholder for a title" : "Another placeholder title")
                    Text(verbatim: "!00 · Placeholder · updated 0m ago")
                        .font(.subheadline)
                }
            }
            .selectionDisabled()
        }
        .redacted(reason: .placeholder)
    }
}

/// The metrics the window's MR and work item rows share with the panel's.
enum SectionRowMetrics {
    /// the symbol column, kept empty where a row has no symbol
    static let symbolColumn: CGFloat = 16
}
