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
        /// GitLab's to-dos for the Inbox
        case inbox
        case mergeRequestList
        /// the selected merge request's description, details with discussions, and changes outline
        case mergeRequestDetails
        case workItemList
        /// the selected work item's description and discussion
        case workItemDetails
        /// the slot labels and the slot items
        case slots
        /// the selected slot item's description and discussion
        case slotItemDetails
        /// the git status of the checkouts
        case workspaces
        /// the item shown under "Opened", and for a merge request or work item its description, details and discussion
        case openedItem
    }

    /// Returns the loads of a section's reload, in order.
    ///
    /// - Parameters:
    ///   - section: the shown section
    ///   - selection: what each section has selected; a detail reloads only with a selected row
    ///   - opened: the item shown under "Opened"; it takes the window in place of the section, so only it reloads
    /// - Returns: the steps; none for Activity, which has nothing to fetch, and none for Digest, whose Reload is
    ///   disabled: a stray ⌘R must not send the person's data to Claude (the user, 2026-11-02)
    static func steps(for section: MainWindowSection, selection: MainWindowSelection, opened: OpenedItem.ID? = nil) -> [Step] {
        if opened != nil {
            return [.openedItem]
        }
        return switch section {
        case .pipelines:
            [.builds]
        case .inbox:
            [.inbox]
        case .mergeRequests:
            selection.mergeRequests == nil ? [.mergeRequestList] : [.mergeRequestList, .mergeRequestDetails]
        case .workItems:
            selection.workItems == nil ? [.workItemList] : [.workItemList, .workItemDetails]
        case .slots:
            selection.slots == nil ? [.slots] : [.slots, .slotItemDetails]
        case .workspaces:
            [.workspaces]
        case .activity, .digest:
            []
        }
    }

    /// Returns the name of a section's reload, for the tooltip, the accessibility label and the menu: "Reload Merge
    /// Requests".
    static func title(for section: MainWindowSection, opened: Bool = false) -> String {
        opened ? "Reload Opened Item" : "Reload \(section.title)"
    }

    /// Whether a section, or the item shown under "Opened", has anything to reload.
    ///
    /// - Parameters:
    ///   - section: the shown section
    ///   - opened: whether an item under "Opened" takes the window
    static func isAvailable(in section: MainWindowSection, opened: Bool = false) -> Bool {
        if opened {
            return true
        }
        return switch section {
        // Activity has nothing to fetch; Digest is written by its own button only, never by a stray ⌘R.
        case .activity, .digest: false
        default: true
        }
    }

    /// Loads a section again.
    ///
    /// - Parameters:
    ///   - section: the shown section
    ///   - selection: what each section has selected
    ///   - opened: the item shown under "Opened"
    ///   - model: the app's model
    @MainActor
    static func run(
        _ section: MainWindowSection, selection: MainWindowSelection, opened: OpenedItem.ID? = nil, model: AppModel
    ) {
        for step in steps(for: section, selection: selection, opened: opened) {
            switch step {
            case .builds:
                model.checkBuilds()
            case .inbox:
                Task { await model.inbox.load() }
            case .mergeRequestList:
                model.reloadList(.mergeRequests)
            case .mergeRequestDetails:
                guard let id = selection.mergeRequests,
                    let mergeRequest = model.mergeRequests.list?.mergeRequest(id: id)
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
                // The related MRs too, whatever the age of their answers (OD-06).
                model.workItems.refreshRelatedOnNextLoad()
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
            case .slotItemDetails:
                guard let id = selection.slots, let workItem = model.slotItems.items.first(where: { $0.id == id }) else {
                    continue
                }
                let source = DescriptionSource(workItem)
                Task {
                    async let description: Void = model.descriptions.load(source, force: true)
                    async let discussion: Void = model.itemDiscussions.load(source, force: true)
                    _ = await (description, discussion)
                }
            case .workspaces:
                model.workspaces.refresh()
            case .openedItem:
                guard let opened else {
                    continue
                }
                // The store skips an item that is loading already, so a second click starts no second request.
                Task { await model.opened.load(opened, force: true) }
                // What the detail adds to the item (description, discussion, changes) bypasses its caches as well.
                if let mergeRequest = model.opened.mergeRequests[opened] {
                    let source = DescriptionSource(mergeRequest)
                    Task {
                        async let description: Void = model.descriptions.load(source, force: true)
                        async let details: Void = model.mergeRequestDetails.load(mergeRequest, force: true)
                        async let changes: Void = model.mergeRequestChanges.open(mergeRequest, force: true)
                        _ = await (description, details, changes)
                    }
                } else if let workItem = model.opened.workItems[opened] {
                    let source = DescriptionSource(workItem)
                    Task {
                        async let description: Void = model.descriptions.load(source, force: true)
                        async let discussion: Void = model.itemDiscussions.load(source, force: true)
                        _ = await (description, discussion)
                    }
                }
            }
        }
    }
}
