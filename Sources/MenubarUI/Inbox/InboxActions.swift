import MenubarCore
import SwiftUI

/// What the Inbox's rows and header do. The store changes the lists at once and goes to GitLab, so every action returns
/// immediately. The gallery passes ``none``.
struct InboxActions {
    /// marks rows done (INBOX-03)
    var done: @MainActor ([InboxEntry]) -> Void = { _ in }
    /// makes done rows pending again
    var restore: @MainActor ([InboxEntry]) -> Void = { _ in }
    /// snoozes rows (INBOX-04)
    var snooze: @MainActor ([InboxEntry], InboxSnoozeChoice) -> Void = { _, _ in }
    /// wakes snoozed rows now
    var wake: @MainActor ([InboxEntry]) -> Void = { _ in }
    /// marks every pending row done
    var markAllDone: @MainActor () -> Void = {}
    /// asks GitLab for the Done list; called while the Done filter shows
    var loadDone: @MainActor () async -> Void = {}
    /// loads the to-dos again, for Try Again
    var retry: @MainActor () -> Void = {}
    /// opens an entry's target in the app, ⌥ in the browser, and notes it as seen; a thing of this app (a Claude answer,
    /// the digest) clears itself as well. Opening a GitLab to-do never marks it done (the user, 2026-11-03).
    var open: @MainActor (InboxEntry) -> Void = { _ in }

    /// actions that do nothing, for the gallery
    static var none: InboxActions { InboxActions() }

    /// Returns the app's actions.
    ///
    /// - Parameter model: the app's model, whose Inbox does the work
    @MainActor
    static func live(model: AppModel, links: GitLabSectionActions, router: WindowRouter) -> InboxActions {
        let store = model.inbox
        return InboxActions(
            // One task per row: each row moves at once, not after the one before it was answered.
            done: { rows in for row in rows { Task { await store.markDone(row) } } },
            restore: { rows in for row in rows { Task { await store.restore(row) } } },
            snooze: { rows, choice in for row in rows { Task { await store.snooze(row, choice) } } },
            wake: { rows in for row in rows { Task { await store.unsnooze(row) } } },
            markAllDone: { Task { await store.markAllDone() } },
            loadDone: { await store.loadDone() },
            retry: { Task { await store.load() } },
            open: { entry in
                InboxOpening.open(entry, store: store, links: links, router: router)
            })
    }
}

/// What opening an Inbox entry does, for the window's rows and the menu bar's.
@MainActor
enum InboxOpening {
    /// Opens the entry's target, notes it as seen and, for a local entry, clears it.
    ///
    /// - Parameters:
    ///   - entry: the entry
    ///   - store: the Inbox
    ///   - links: how links open: in the app, ⌥ in the browser
    ///   - router: the window's router, for a `megamonitor://` link of a thing of this app
    static func open(_ entry: InboxEntry, store: InboxStore, links: GitLabSectionActions, router: WindowRouter) {
        store.seen.markSeen(entry.id)
        if let url = entry.targetURL {
            if let route = AppRoute(url: url) {
                switch route {
                case .open(let section): router.open(section)
                case .settings(let pane): router.open(.settings(pane: pane))
                default: router.open(.main)
                }
            } else {
                links.follow(url)
            }
        }
        if isLocal(entry) {
            Task { await store.markDone(entry) }
        }
    }

    /// whether the entry is a thing of this app, which opening clears
    nonisolated static func isLocal(_ entry: InboxEntry) -> Bool {
        if case .event(let event) = entry.source { event.source == .local } else { false }
    }
}
