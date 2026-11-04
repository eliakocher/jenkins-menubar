import Foundation

extension AppModel {
    /// Hands the Inbox's announced events to the panel or the banner their kind asks for (Task 7.03). The Inbox already
    /// leaves out what was announced before, on this launch or an earlier one, so nothing is delivered twice.
    func connectInboxDelivery() {
        inbox.onEvents = { [weak self] routed in
            guard let self else {
                return
            }
            Task { await self.deliver(routed) }
        }
    }

    /// Delivers events as the table of Settings → Notifications chose: a ``InboxDelivery/popUp`` shows in the app's
    /// window, a ``InboxDelivery/banner`` posts a macOS banner, ``InboxDelivery/inbox`` does nothing more (the entry is
    /// the Inbox's own). A banner that macOS doesn't allow stays an entry of the Inbox.
    ///
    /// - Parameter routed: the events of one load
    func deliver(_ routed: [RoutedInboxEvent]) async {
        for item in routed {
            // GitLab's failed pipeline waits for the failed build of the same merge request: if it comes, the build's
            // pop-up is the one the user sees (``HeldPipelineAlerts``).
            if item.event.kind == .pipelineFailed, item.delivery == .popUp || item.delivery == .banner {
                heldPipelineAlerts.hold(item.event, clock: dependencies.clock) { [weak self] event in
                    await self?.showDelivered(RoutedInboxEvent(event: event, routes: item.routes, delivery: item.delivery))
                }
                continue
            }
            await showDelivered(item)
        }
    }

    /// Shows one event as its choice says.
    private func showDelivered(_ item: RoutedInboxEvent) async {
        let effects = dependencies.effects
        switch item.delivery {
        case .popUp:
            await effects.showInboxPanel(item.event)
        case .banner:
            if await !effects.postInboxBanner(item.event) {
                await log.log(.info, .app, "Inbox: macOS doesn't show banners, so \(item.event.kind.title) stays in the Inbox")
            }
        case .inbox, .off:
            break
        }
    }
}
