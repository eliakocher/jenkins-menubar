import MenubarCore

/// What the main window's Reload (the toolbar's ↻, View-side ⌘R) loads again: only the shown section, not everything
/// (the user, 2026-10-30). Check Now stays the app-wide refresh, in the menu bar pane, the Builds menu and as ⇧⌘R.
///
/// Every step bypasses the caches: the lists load at once whatever the age of their data, and the selected row's
/// description, discussion, details and changes load again although they belong to the row's last update.
enum MainWindowReload {
    /// one load of a reload
    enum Step: Hashable {
        /// the Jenkins builds of all projects
        case builds
        case mergeRequestList
        /// the selected merge request's description, details with discussions, and changes outline
        case mergeRequestDetails
        case workItemList
        /// the selected work item's description and discussion
        case workItemDetails
        /// the slot labels and the slot items
        case slots
        /// the git status of the checkouts
        case workspaces
    }

    /// Returns the loads of a section's reload, in order.
    ///
    /// - Parameters:
    ///   - section: the shown section
    ///   - selection: what each section has selected; a detail reloads only with a selected row
    /// - Returns: the steps; none for Activity, which has nothing to fetch
    static func steps(for section: MainWindowSection, selection: MainWindowSelection) -> [Step] {
        switch section {
        case .pipelines:
            [.builds]
        case .mergeRequests:
            selection.mergeRequests == nil ? [.mergeRequestList] : [.mergeRequestList, .mergeRequestDetails]
        case .workItems:
            selection.workItems == nil ? [.workItemList] : [.workItemList, .workItemDetails]
        case .slots:
            [.slots]
        case .workspaces:
            [.workspaces]
        case .activity:
            []
        }
    }

    /// Returns the name of a section's reload, for the tooltip, the accessibility label and the menu: "Reload Merge
    /// Requests".
    static func title(for section: MainWindowSection) -> String {
        "Reload \(section.title)"
    }

    /// Whether a section has anything to reload.
    static func isAvailable(in section: MainWindowSection) -> Bool {
        section != .activity
    }

    /// Loads a section again.
    ///
    /// - Parameters:
    ///   - section: the shown section
    ///   - selection: what each section has selected
    ///   - model: the app's model
    @MainActor
    static func run(_ section: MainWindowSection, selection: MainWindowSelection, model: AppModel) {
        for step in steps(for: section, selection: selection) {
            switch step {
            case .builds:
                model.checkBuilds()
            case .mergeRequestList:
                model.reloadList(.mergeRequests)
            case .mergeRequestDetails:
                guard let id = selection.mergeRequests,
                    let mergeRequest = model.mergeRequests.list?.mergeRequests.first(where: { $0.id == id })
                else {
                    continue
                }
                let source = DescriptionSource(mergeRequest)
                Task {
                    async let description: Void = model.descriptions.load(source, force: true)
                    async let details: Void = model.mergeRequestDetails.load(mergeRequest, force: true)
                    async let changes: Void = model.mergeRequestChanges.open(mergeRequest, force: true)
                    _ = await (description, details, changes)
                }
            case .workItemList:
                model.reloadList(.workItems)
            case .workItemDetails:
                guard let id = selection.workItems, let workItem = model.workItems.lists?.all.first(where: { $0.id == id }) else {
                    continue
                }
                let source = DescriptionSource(workItem)
                Task {
                    async let description: Void = model.descriptions.load(source, force: true)
                    async let discussion: Void = model.itemDiscussions.load(source, force: true)
                    _ = await (description, discussion)
                }
            case .slots:
                Task {
                    await model.slotLabels.load(force: true)
                    await model.slotItems.load(slots: model.slotNamesToLoad(), force: true)
                }
            case .workspaces:
                model.workspaces.refresh()
            }
        }
    }
}
