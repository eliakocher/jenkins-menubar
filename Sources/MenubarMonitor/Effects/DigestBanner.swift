import MenubarCore
import UserNotifications

extension NativeEffects {
    /// Posts the morning digest the user scheduled as a banner (AI-04): "Your Digest", marked as Claude's, with the
    /// digest's text, which the banner shows in full when expanded. Nothing shows while banners aren't allowed; the
    /// digest is still in the main window's Digest.
    ///
    /// - Parameter text: the digest
    func postDigest(_ text: String) async {
        guard await bannersAllowed() else {
            AppLog.warning("The morning digest is ready, but banners aren't allowed: it waits in the main window")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Your Digest"
        content.subtitle = "Written by Claude"
        content.body = text
        content.threadIdentifier = "digest"
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "digest-\(UUID().uuidString)", content: content, trigger: nil))
        } catch {
            AppLog.warning("Couldn't post the morning digest: \(error.localizedDescription)")
        }
    }
}
