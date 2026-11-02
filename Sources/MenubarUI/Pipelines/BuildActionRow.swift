import MenubarCore
import SwiftUI

/// The build detail's action row under the header, a ``DetailActionRow`` (the user, 2026-10-30: "represent them directly
/// in the view, so they're not hidden behind a menu"). The ⋯ menu keeps only the rare ones. Rebuild or Cancel Rebuild,
/// Notifications, Hide Until the Next Build, Stop Watching, the console and the test results in Jenkins, and Copy
/// Link, each where it applies.
struct BuildActionRow: View {
    let model: BuildDetailModel
    let actions: PanelActions

    var body: some View {
        DetailActionRow {
            if case .build(let row) = model.item {
                rebuild(row)
            }
            JobNotificationsMenu(notifications: model.notifications, asButton: true) {
                actions.setJobNotifications(model.item.id, $0)
            }
            if model.canHide, case .build(let row) = model.item {
                button("Hide Until the Next Build", "eye.slash", help: "Takes the build off the lists until the job's next build") {
                    actions.hide(row.build)
                }
            }
            if model.canStopWatching {
                button("Stop Watching", "eye.slash.circle", help: "Stops watching this job") { actions.stopWatching(model.item.id) }
            }
            ForEach(model.links.filter { $0.kind == .console || $0.kind == .testResults }) { link in
                button(link.kind == .console ? "Console in Jenkins" : "Test Results in Jenkins", symbol(of: link), help: link.title) {
                    actions.open(link.url)
                }
            }
            if let primary = model.primary, case .build = model.item {
                CopyLinkButton(help: "Copies the build's link in Jenkins") { actions.copy(primary.url) }
            }
        }
    }

    /// Rebuild, or Cancel Rebuild while the new build is queued (PIPE-09).
    @ViewBuilder
    private func rebuild(_ row: BuildRowModel) -> some View {
        if model.canRebuild {
            if model.rebuild?.canCancel == true {
                button("Cancel Rebuild", "xmark", help: "Removes the new build from Jenkins's queue") {
                    actions.cancelRebuild(row.build.jobKey)
                }
            } else {
                button("Rebuild", "arrow.clockwise", help: "Starts the job again with this build's parameters") {
                    actions.rebuildBuild(row.build.id)
                }
                .disabled(model.rebuild?.isUnderWay == true)
            }
        }
    }

    private func button(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        DetailActionButton(title, symbol, help: help, action: action)
    }

    private func symbol(of link: BuildLink) -> String {
        link.kind == .console ? "terminal" : "checklist"
    }
}
