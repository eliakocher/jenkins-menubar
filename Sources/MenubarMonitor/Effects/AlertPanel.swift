import AppKit
import MenubarCore
import MenubarUI
import SwiftUI

/// The alert window (ALERT-03, INBOX-14): one at a time, which holds every finished build's alert and every Inbox event
/// delivered as a pop-up that came while it was open.
///
/// It shows centered on the main screen. One item is its own pop-up, with Dismiss. A second item that comes while it is open
/// turns the window into one summary (the user, 2026-11-04: "we close the previous and we show a small summary with a 'go
/// to inbox'"): a list with a row per item, Open Inbox and Dismiss All. A row opens its build or item in the app and goes;
/// the summary is a pop-up again when one row is left. Every pop-up already leaves its entry in the Inbox, so no row needs
/// more buttons. The window stays until a button, Esc, ⌘. or ⌘W closes it, and its height follows the content, with the top
/// left corner fixed.
@MainActor
final class AlertPanels: NSObject, NSWindowDelegate {
    private var panel: AlertPanel?
    private let model = AlertWindowModel()
    /// the buttons' effects, those of the newest `show` of a build's alert
    private var effects: Effects?
    /// runs an Inbox event's Show, Done and Snooze 1 Hour; the shell's, from the newest `show` of an event
    private var perform: @MainActor (InboxDeliveryAction, InboxEvent) async -> Problem? = { _, _ in nil }
    /// opens the Inbox in the app, for the summary's Open Inbox
    var openInbox: @MainActor () -> Void = {}

    /// the effects of a build alert's buttons
    private struct Effects {
        var rebuild: @MainActor (BuildID) -> Void
        var hide: @MainActor (BuildID) -> Void
        var open: @MainActor (URL, Bool) -> Void
        var rebuildWithChanges: @MainActor (BuildID) -> Void
    }

    /// Shows a build's alert in the window, in front of every window, without taking the keyboard; the window opens for the
    /// first item and turns into a summary with the later ones.
    ///
    /// - Parameters:
    ///   - alert: the alert
    ///   - notificationsOff: whether it shows because its banner couldn't, which its footnote says
    ///   - rebuild: starts the build's rebuild, for the Rebuild button (PIPE-09)
    ///   - rebuildWithChanges: opens the "Rebuild with Changes…" sheet for the build (PIPE-09)
    ///   - hide: hides the build until its job's next build, for the Hide button (HIDE-01)
    ///   - open: shows a link in the app (`true`) or opens it in the browser (`false`)
    func show(
        _ alert: BuildAlert, notificationsOff: Bool, rebuild: @escaping @MainActor (BuildID) -> Void,
        rebuildWithChanges: @escaping @MainActor (BuildID) -> Void, hide: @escaping @MainActor (BuildID) -> Void,
        open: @escaping @MainActor (URL, Bool) -> Void
    ) {
        effects = Effects(rebuild: rebuild, hide: hide, open: open, rebuildWithChanges: rebuildWithChanges)
        add(AlertWindowItem(alert: alert, notificationsOff: notificationsOff))
    }

    /// Shows an Inbox event in the window, like a build's alert.
    ///
    /// - Parameters:
    ///   - event: the event
    ///   - perform: runs Show, Done and Snooze 1 Hour for the event; answers why GitLab refused a Done, which the page then
    ///     shows inline and stays
    func show(_ event: InboxEvent, perform: @escaping @MainActor (InboxDeliveryAction, InboxEvent) async -> Problem?) {
        self.perform = perform
        add(AlertWindowItem(event: event))
    }

    private func add(_ item: AlertWindowItem) {
        model.items.add(item)
        if let panel {
            panel.title = Self.title(of: model)
            // Never makeKeyAndOrderFront or activate: typing in another app goes on (ALERT-03).
            panel.orderFrontRegardless()
            return
        }
        // The system's window lists show the title as it is, so it gets the headline without the emoji (ALERT-03).
        let panel = AlertPanel(title: Self.title(of: model))
        let view = AlertWindowView(
            model: model,
            rebuildWithChanges: { [weak self] alert in
                if alert.content.offersRebuild, let build = alert.content.rebuild {
                    self?.effects?.rebuildWithChanges(build)
                }
                self?.dismiss(alert)
            },
            perform: { [weak self] alert, action in self?.perform(action, for: alert) },
            performEvent: { [weak self] action, event in self?.run(action, for: event) },
            openItem: { [weak self] item in self?.open(item) },
            openInbox: { [weak self] in self?.showInbox() },
            dismissAll: { [weak self] in self?.dismissAll() },
            onSizeChange: { [weak panel] size in panel?.fit(to: size) })
        let hosting = NSHostingView(rootView: view)
        // The panel keeps `.titled` (so it can become key) with a hidden title bar; without this the content honours
        // that title bar's safe area and starts ~28 pt down, leaving an untinted strip of glass at the top.
        hosting.safeAreaRegions = []
        panel.setContent(hosting)
        panel.delegate = self
        // Esc takes the pop-up it is on, or every row of a summary; ⌘W takes the whole window. The coffee break is the
        // exception: only its button takes it.
        panel.onCancel = { [weak self] in
            guard let self else {
                return
            }
            if let item = model.items.single {
                if !item.isMandatory {
                    dismiss(item.id)
                }
            } else {
                dismissAll()
            }
        }
        panel.center()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private static func title(of model: AlertWindowModel) -> String {
        model.items.windowTitle ?? ""
    }

    /// Runs a button of a build's alert, then dismisses it.
    private func perform(_ action: AlertContent.Action, for alert: BuildAlert) {
        if action == .rebuild, alert.content.offersRebuild, let build = alert.content.rebuild {
            effects?.rebuild(build)
        } else if action == .hide, let build = alert.content.hide {
            effects?.hide(build)
        } else if let url = alert.content.url(for: action) {
            // Show Build and Show MR stay in the app; a preview's made-up build has nothing to show there.
            effects?.open(url, action.showsInApp && alert.content.isLive)
        }
        dismiss(alert)
    }

    /// Runs a button of an Inbox event, then dismisses it. A Done that GitLab refused keeps the page, with the reason on it.
    private func run(_ action: InboxDeliveryAction, for event: InboxEvent) {
        let id = AlertWindowItem(event: event).id
        let perform = perform
        guard action == .done else {
            if action != .dismiss {
                Task { _ = await perform(action, event) }
            }
            dismiss(id)
            return
        }
        guard model.busy.insert(event.id).inserted else {
            return
        }
        Task {
            let refused = await perform(action, event)
            model.busy.remove(event.id)
            if let refused {
                model.refusals[event.id] = refused
            } else {
                dismiss(id)
            }
        }
    }

    /// A click on a summary row: the item opens in the app, as the pop-up's Show or Show Build does, and the row goes.
    private func open(_ item: AlertWindowItem) {
        switch item.payload {
        case .build(let alert, _):
            perform(alert.content.defaultAction, for: alert)
        case .event(let event):
            run(.show, for: event)
        }
    }

    /// Open Inbox: the Inbox opens in the app, and the window with its rows closes.
    private func showInbox() {
        openInbox()
        dismissAll()
    }

    private func dismiss(_ alert: BuildAlert) {
        dismiss(AlertWindowItem(alert: alert, notificationsOff: false).id)
    }

    /// Takes an item out; the window closes with the last one.
    private func dismiss(_ id: String) {
        model.items.dismiss(id)
        if model.items.isEmpty {
            panel?.close()
        } else {
            panel?.title = Self.title(of: model)
        }
    }

    private func dismissAll() {
        model.items.dismissAll()
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? AlertPanel, closing === panel else {
            return
        }
        closing.delegate = nil
        // A close by ⌘W or the system leaves no item behind, so the next one opens a fresh window.
        model.items.dismissAll()
        panel = nil
    }
}
