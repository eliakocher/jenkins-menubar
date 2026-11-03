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
    /// clears the note about a refused write
    var dismissNote: @MainActor () -> Void = {}
    /// loads the to-dos again, for Try Again
    var retry: @MainActor () -> Void = {}
    /// opens an entry's target in the app, ⌥ in the browser, and notes it as seen; a thing of this app (a Claude answer,
    /// the digest) clears itself as well. Opening a GitLab to-do never marks it done (the user, 2026-11-03).
    var open: @MainActor (InboxEntry) -> Void = { _ in }
    /// adds a to-do of my own from the quick-add field's words; a link or `!123` in them becomes the chip (INBOX-16)
    var addTodo: @MainActor (String) -> Void = { _ in }
    /// keeps my to-do's form: the id of the one edited, or `nil` for a new one
    var saveTodo: @MainActor (String?, MyTodoDraft) -> Void = { _, _ in }
    /// deletes my to-dos for good
    var deleteTodos: @MainActor ([InboxEntry]) -> Void = { _ in }
    /// moves my pending to-dos as a drag does: the offsets among them, and where they are dropped
    var moveTodos: @MainActor (IndexSet, Int) -> Void = { _, _ in }
    /// reads the form's link field: a pasted GitLab or Jenkins link, or `!123`
    var parseLink: @MainActor (String) -> MyTodoLink? = { _ in nil }

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
            dismissNote: { store.dismissActionProblem() },
            retry: { Task { await store.load() } },
            open: { entry in
                InboxOpening.open(entry, store: store, links: links, router: router)
            },
            addTodo: { text in store.addMyTodo(text) },
            saveTodo: { id, draft in
                if let id {
                    store.updateMyTodo(id, with: draft)
                } else {
                    store.addMyTodo(draft)
                }
            },
            deleteTodos: { rows in for row in rows { if let todo = row.myTodo { store.deleteMyTodo(todo.id) } } },
            moveTodos: { source, destination in store.moveMyTodos(from: source, to: destination) },
            parseLink: { text in MyTodoLink.parseLink(text, context: store.linkContext) })
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
        // One of my own to-dos stays as it is: its checkbox is what finishes it.
        if !entry.isMine {
            store.seen.markSeen(entry.id)
        }
        if let url = entry.targetURL {
            if let route = AppRoute(url: url) {
                switch route {
                case .open(let section): router.open(section)
                case .settings(let pane): router.open(.settings(pane: pane))
                case .openItem(let link, let card): links.follow(link, card: card)
                default: router.open(.main)
                }
            } else {
                // A Claude answer shows its card: the item opens, then scrolls to it.
                links.follow(url, card: entry.focusCard)
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
