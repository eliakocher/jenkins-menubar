import MenubarCore
import SwiftUI

/// The toolbar's "Open in GitLab" or "Open in Jenkins" for what the window shows: always there, next to Reload, in the
/// one place and symbol in every section, so the item never moves with the section; without a link to open it is
/// disabled (`docs/design/main-window.md`, Toolbar).
struct DetailLink: Equatable {
    /// "Open in GitLab" or "Open in Jenkins", the item's tooltip and menu title
    var title: String
    /// what it opens; `nil` without a selection that has a link, which disables the item
    var url: URL?

    /// Where a link opens: GitLab, or Jenkins for builds.
    enum Target {
        case gitLab
        case jenkins

        var title: String {
            switch self {
            case .gitLab: "Open in GitLab"
            case .jenkins: "Open in Jenkins"
            }
        }
    }

    /// - Parameters:
    ///   - target: where the link opens
    ///   - url: the link; `nil` when there is nothing to open
    init(_ target: Target, url: URL? = nil) {
        title = target.title
        self.url = url
    }

    /// Returns the link of what the window shows: the selected row of the shown section, or the item under "Opened".
    /// The title names Jenkins for a build (Pipelines, or an opened build) and GitLab everywhere else, also without a
    /// link, which leaves the item disabled.
    ///
    /// - Parameters:
    ///   - model: the app's model
    ///   - router: the router, which holds the section and the selections
    @MainActor
    static func current(_ model: AppModel, router: WindowRouter) -> DetailLink {
        let url = MainWindowLinks.selected(model, router: router)
        if let opened = router.opened {
            return DetailLink(model.opened.item(opened)?.kind == .build ? .jenkins : .gitLab, url: url)
        }
        return DetailLink(router.section == .pipelines ? .jenkins : .gitLab, url: url)
    }
}
