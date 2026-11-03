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

    /// Delivers events as the rules chose: a ``InboxDelivery/bigPanel`` shows in the app's panel, a
    /// ``InboxDelivery/desktopNotification`` posts a macOS banner, ``InboxDelivery/inboxOnly`` does nothing more. A banner
    /// that macOS doesn't allow stays an entry of the Inbox.
    ///
    /// - Parameter routed: the events of one load
    func deliver(_ routed: [RoutedInboxEvent]) async {
        let effects = dependencies.effects
        for item in routed {
            // Muted for the hour, nothing pops up; the event stays in the Inbox (HOT-09).
            if item.delivery != .inboxOnly, alertMute.isMuted {
                await log.log(.info, .app, "Inbox: alerts are muted, so \(item.event.kind.title) stays in the Inbox")
                continue
            }
            switch item.delivery {
            case .bigPanel:
                await effects.showInboxPanel(item.event)
            case .desktopNotification:
                if await !effects.postInboxBanner(item.event) {
                    await log.log(.info, .app, "Inbox: macOS doesn't show banners, so \(item.event.kind.title) stays in the Inbox")
                }
            case .inboxOnly:
                break
            }
        }
    }
}
