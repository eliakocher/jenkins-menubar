import MenubarCore
import SwiftUI

/// Opens GitLab's new issue page for a New Work Item entry point (NEW-01 to NEW-04): the failed tests of a build are
/// asked for first when the build has some, then the link opens in the browser. Nothing is written to GitLab.
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
            Task { @MainActor in
                if let url = await link(for: source, model: model) {
                    open(url)
                }
            }
        }
    }

    /// Returns the link of an entry point, after loading the failed tests it lists.
    static func link(for source: NewWorkItemSource, model: AppModel) async -> URL? {
        var tests: [FailedTest]?
        if let build = source.failedTestsBuild {
            await model.failedTests.load(build)
            if case .loaded(let loaded) = model.failedTests.state(of: build) {
                tests = loaded
            }
        }
        return NewWorkItem.link(for: source.draft(failedTests: tests), team: model.pipelines.project.team)
    }
}
