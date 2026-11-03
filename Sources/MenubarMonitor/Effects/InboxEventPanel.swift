import AppKit
import MenubarCore
import MenubarUI
import SwiftUI

/// The Inbox's big panel (Task 7.03, INBOX-14): one window at a time that holds every event delivered as ``InboxDelivery/bigPanel``,
/// in the look of the failed-build alert. It is the alert window's ``AlertPanel`` with its own content: centered on the
/// main screen, non-activating and floating, the newest event as its first page. An event that comes while it is open joins
/// it; "1 of 3" and the arrows page through them. Show, Done and Snooze 1 Hour act on the shown event and take its page,
/// Dismiss takes the page and leaves the entry in the Inbox, Dismiss All closes the window, and so do Esc (the shown page),
/// ⌘. and ⌘W.
@MainActor
final class InboxEventPanels: NSObject, NSWindowDelegate {
    private var panel: AlertPanel?
    private let model = InboxEventPanelModel()
    /// runs a button's action for an event; the shell's
    private var perform: @MainActor (InboxDeliveryAction, InboxEvent) -> Void = { _, _ in }

    /// Shows an event in the panel, in front of every window, without taking the keyboard; the panel opens for the first
    /// event and takes the later ones as pages.
    ///
    /// - Parameters:
    ///   - event: the event
    ///   - perform: runs Show, Done and Snooze 1 Hour for the event
    func show(_ event: InboxEvent, perform: @escaping @MainActor (InboxDeliveryAction, InboxEvent) -> Void) {
        self.perform = perform
        model.pages.add(event)
        if let panel {
            panel.title = Self.title(of: event)
            // Never makeKeyAndOrderFront or activate: typing in another app goes on (ALERT-03).
            panel.orderFrontRegardless()
            return
        }
        let panel = AlertPanel(title: Self.title(of: event))
        let view = InboxEventPanelView(
            model: model,
            perform: { [weak self] action, event in self?.run(action, for: event) },
            dismissAll: { [weak self] in self?.dismissAll() },
            onSizeChange: { [weak panel] size in panel?.fit(to: size) })
        let hosting = NSHostingView(rootView: view)
        hosting.safeAreaRegions = []
        panel.setContent(hosting)
        panel.delegate = self
        panel.onCancel = { [weak self] in
            if let id = self?.model.pages.current?.id {
                self?.dismiss(id)
            }
        }
        panel.center()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private static func title(of event: InboxEvent) -> String {
        event.kind == .coffeeBreak ? "Coffee Break" : event.headline
    }

    /// Runs a button of a page, then takes the page.
    private func run(_ action: InboxDeliveryAction, for event: InboxEvent) {
        if action != .dismiss {
            perform(action, event)
        }
        dismiss(event.id)
    }

    /// Takes a page out; the window closes with the last one.
    private func dismiss(_ id: String) {
        model.pages.dismiss(id)
        if model.pages.isEmpty {
            panel?.close()
        } else if let current = model.pages.current {
            panel?.title = Self.title(of: current)
        }
    }

    private func dismissAll() {
        model.pages.dismissAll()
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? AlertPanel, closing === panel else {
            return
        }
        closing.delegate = nil
        // A close by ⌘W or the system leaves no page behind, so the next event opens a fresh window.
        model.pages.dismissAll()
        panel = nil
    }
}
