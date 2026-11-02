import MenubarCore
import SwiftUI

/// Opens GitLab's new issue page for a New Work Item entry point (NEW-01, NEW-02, NEW-04) in the browser. Nothing is
/// written to GitLab.
@MainActor
enum NewWorkItemLauncher {
    /// Returns whether the team values can make a link: the GitLab URL and the project.
    ///
    /// - Parameter model: the app's model
    static func canOpen(_ model: AppModel) -> Bool {
        let team = model.pipelines.project.team
        return team.gitLab != nil && !team.gitLabProject.isEmpty
    }

    /// Returns the actions' closure of the entry points, or `nil` while the team values can't make a link, so the menus
    /// don't offer them.
    ///
    /// - Parameters:
    ///   - model: the app's model
    ///   - open: opens a web page
    static func action(model: AppModel, open: @escaping @MainActor (URL) -> Void) -> (@MainActor (NewWorkItemSource) -> Void)? {
        guard canOpen(model) else { return nil }
        return { source in
            if let url = NewWorkItem.link(for: source.draft, team: model.pipelines.project.team) {
                open(url)
            }
        }
    }
}
