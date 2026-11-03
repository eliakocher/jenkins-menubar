import AppKit
import MenubarCore
import UserNotifications

/// Opens a banner's link when it, or one of its actions, is clicked (ALERT-08), starts the rebuild of its Rebuild
/// (PIPE-09), hides the build of its Hide (HIDE-01), and shows banners while the app is frontmost too (ALERT-03).
///
/// It is the notification center's delegate before the app finishes launching, so a click that starts the app reaches
/// it as well.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// the user info key of a slot notice's link
    static let noticeURLKey = "noticeURL"

    private let rebuild: @MainActor @Sendable (BuildID) -> Void
    private let hide: @MainActor @Sendable (BuildID) -> Void
    private let open: @MainActor @Sendable (URL, Bool) -> Void
    private let inboxAction: @MainActor @Sendable (InboxDeliveryAction, InboxEvent) -> Void

    /// - Parameters:
    ///   - rebuild: starts a build's rebuild, once the app has launched
    ///   - hide: hides a build until its job's next build, once the app has launched
    ///   - open: shows a link in the app (`true`) or opens it in the browser (`false`), once the app has launched
    ///   - inboxAction: runs Show, Mark Done or Snooze 1 Hour of an Inbox event's banner, once the app has launched (INBOX-14)
    init(
        rebuild: @escaping @MainActor @Sendable (BuildID) -> Void,
        hide: @escaping @MainActor @Sendable (BuildID) -> Void,
        open: @escaping @MainActor @Sendable (URL, Bool) -> Void,
        inboxAction: @escaping @MainActor @Sendable (InboxDeliveryAction, InboxEvent) -> Void
    ) {
        self.rebuild = rebuild
        self.hide = hide
        self.open = open
        self.inboxAction = inboxAction
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        // A slot notice carries only the link a click opens (SLOT-04).
        if action == UNNotificationDefaultActionIdentifier,
           let link = response.notification.request.content.userInfo[Self.noticeURLKey] as? String, let url = URL(string: link)
        {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return
        }
        // An Inbox event's banner: Show, Mark Done, Snooze 1 Hour, or a click on the banner, which shows the event (INBOX-14).
        if let event = InboxBanner.event(from: response.notification.request.content.userInfo) {
            let clicked = action == UNNotificationDefaultActionIdentifier ? nil : action
            guard action != UNNotificationDismissActionIdentifier, let intent = InboxBanner.action(forIdentifier: clicked) else {
                return
            }
            let inboxAction = inboxAction
            await MainActor.run { inboxAction(intent, event) }
            return
        }
        guard action != UNNotificationDismissActionIdentifier,
              let payload = BannerPayload(userInfo: response.notification.request.content.userInfo)
        else {
            return
        }
        let clicked = action == UNNotificationDefaultActionIdentifier ? nil : action
        guard let intent = payload.intent(forAction: clicked) else {
            return
        }
        let (rebuild, hide, open) = (rebuild, hide, open)
        await MainActor.run {
            switch intent {
            case .rebuild(let build): rebuild(build)
            case .hide(let build): hide(build)
            case .show(let url): open(url, true)
            case .open(let url): open(url, false)
            }
        }
    }
}
