import AppKit
import MenubarCore
import MenubarUI
import UserNotifications

/// The alerts' effects on the Mac (Task 4.4): the alert window, banners and sounds.
///
/// - The alert window is one ``AlertPanel`` that holds every build alert and every Inbox pop-up: one shows as itself, two
///   or more as a summary; non-activating and floating, so it never takes the keyboard by itself (ALERT-03,
///   `docs/design/alert.md`).
/// - Banners go through UNUserNotificationCenter, in the categories `build` and `build-and-mr`, and with Rebuild for a
///   failed, unstable or aborted build `build-rebuild` and `build-and-mr-rebuild` (PIPE-09), and for a real build, not a
///   preview, the same four with the suffix `-live`, which add Open Console and Hide Until the Next Build; the payload is
///   what the ``NotificationDelegate`` acts on (ALERT-08). A finished build whose banner couldn't show gets its window with the
///   footnote instead.
/// - Sounds play through `NSSound`, from `/System/Library/Sounds`.
@MainActor
final class NativeEffects: Effects {
    /// whether the app runs from its bundle: UNUserNotificationCenter stops a process that has none, like a run from
    /// `.build`
    nonisolated static var canNotify: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// the placeholder banners show when previews are hidden
    private static let hiddenPreviewsPlaceholder = "Jenkins build"

    /// the alert window, also for the events delivered as ``InboxDelivery/popUp`` (INBOX-14)
    private let panels = AlertPanels()
    /// the finished builds whose banner couldn't show, so their window says why (ALERT-03)
    private var bannerFallbacks: Set<UUID> = []
    /// starts a build's rebuild, for the alert window's Rebuild; the app delegate sets it to the shell's (PIPE-09)
    var onRebuild: @MainActor (BuildID) -> Void = { _ in }
    /// opens the "Rebuild with Changes…" sheet for a build, for the alert window's Rebuild menu; the app delegate sets it
    /// to the shell's (PIPE-09)
    var onRebuildWithChanges: @MainActor (BuildID) -> Void = { _ in }
    /// hides a build until its job's next build, for the alert window's Hide; the app delegate sets it to the shell's
    /// (HIDE-01)
    var onHide: @MainActor (BuildID) -> Void = { _ in }
    /// shows a link in the app (`true`) or opens it in the browser (`false`), for the alert window's buttons; the app
    /// delegate sets it to the shell's. Never `NSWorkspace`: while the app is the default browser, the link would come
    /// back to it.
    var onOpen: @MainActor (URL, Bool) -> Void = { _, _ in }

    /// runs a button of the Inbox's pop-up or of an Inbox event's banner; the app delegate sets it to the shell's
    var onInboxAction: @MainActor (InboxDeliveryAction, InboxEvent) async -> Problem? = { _, _ in nil }

    /// opens the Inbox in the app, for the alert window's Open Inbox; the app delegate sets it to the shell's
    var onOpenInbox: @MainActor () -> Void {
        get { panels.openInbox }
        set { panels.openInbox = newValue }
    }

    func showInboxPanel(_ event: InboxEvent) async {
        panels.show(event) { [weak self] action, event in await self?.onInboxAction(action, event) }
    }

    /// Posts an Inbox event as a macOS banner with Show, Mark Done and Snooze 1 Hour (INBOX-14). It never plays a sound.
    func postInboxBanner(_ event: InboxEvent) async -> Bool {
        guard await bannersAllowed() else {
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = InboxBanner.title(of: event)
        content.subtitle = InboxBanner.subtitle(of: event)
        content.body = InboxBanner.body(of: event)
        content.categoryIdentifier = InboxBanner.category(for: event)
        content.userInfo = InboxBanner.userInfo(for: event)
        content.threadIdentifier = "inbox-\(event.kind.rawValue)"
        content.sound = nil
        if event.kind == .coffeeBreak, let attachment = Self.coffeeAttachment() {
            content.attachments = [attachment]
        }
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "inbox-\(event.id)", content: content, trigger: nil))
            return true
        } catch {
            AppLog.warning("The banner of an Inbox event (\(event.kind.rawValue)) didn't post: \(error.localizedDescription)")
            return false
        }
    }

    /// The coffee break's butler (`coffee.png` in the bundle) as a banner's picture. macOS moves an attachment's file into
    /// its own store, so it gets a temporary copy, never the bundle's file. `nil` without the art or when the copy fails:
    /// the banner then shows as before.
    private static func coffeeAttachment() -> UNNotificationAttachment? {
        guard let source = Bundle.main.url(forResource: "coffee", withExtension: "png") else {
            return nil
        }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("megamonitor-banner-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent("coffee.png")
            try FileManager.default.copyItem(at: source, to: copy)
            return try UNNotificationAttachment(identifier: "coffee", url: copy, options: nil)
        } catch {
            AppLog.warning("The coffee break's picture couldn't be attached: \(error.localizedDescription)")
            return nil
        }
    }

    func showAlertWindow(_ alert: BuildAlert) async {
        panels.show(
            alert, notificationsOff: bannerFallbacks.remove(alert.id) != nil,
            rebuild: { [weak self] build in self?.onRebuild(build) },
            rebuildWithChanges: { [weak self] build in self?.onRebuildWithChanges(build) },
            hide: { [weak self] build in self?.onHide(build) },
            open: { [weak self] url, inApp in self?.onOpen(url, inApp) })
    }

    func postBanner(_ alert: BuildAlert) async -> Bool {
        let posted = await post(alert)
        // The announcer shows the window next for a build of mine; a watched build's banner just stays quiet.
        if !posted, !alert.content.isWatched {
            bannerFallbacks.insert(alert.id)
        }
        return posted
    }

    func playSound(_ sound: AlertContent.Sound) async {
        guard let player = NSSound(named: sound.rawValue) else {
            AppLog.warning("No system sound named \(sound.rawValue)")
            return
        }
        player.play()
    }

    func postNotice(_ notice: SlotNotice) async -> Bool {
        guard await bannersAllowed() else {
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.subtitle
        content.body = notice.body
        content.userInfo = [NotificationDelegate.noticeURLKey: notice.url.absoluteString]
        // A notice is quiet: never a sound (SLOT-04).
        content.sound = nil
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "slot-\(notice.slot)", content: content, trigger: nil))
            return true
        } catch {
            AppLog.warning("The banner of slot \(notice.slot) didn't post: \(error.localizedDescription)")
            return false
        }
    }

    /// whether banners show: notifications are allowed and the app's style isn't None (ALERT-03, APP-04)
    func bannersAllowed() async -> Bool {
        guard Self.canNotify else {
            return false
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return settings.alertStyle != .none
        default: return false
        }
    }

    /// Asks for permission to show banners, with sounds, as the welcome flow does (APP-04). macOS asks only once; later
    /// calls return the answer given.
    ///
    /// - Returns: whether banners are allowed now
    func requestNotificationPermission() async -> Bool {
        guard Self.canNotify else {
            return false
        }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await bannersAllowed()
    }

    /// Reads whether macOS asked yet and what the answer was, for the welcome flow and Settings → General (APP-04). A
    /// run outside the bundle can't notify, so it reads as off.
    ///
    /// - Returns: never asked, allowed, or off (denied, or the style None)
    func notificationPermission() async -> NotificationPermission {
        guard Self.canNotify else {
            return .off
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            return .notAsked
        }
        return await bannersAllowed() ? .allowed : .off
    }

    /// Opens System Settings → Notifications at the app's pane, where people allow its banners again (APP-04). The
    /// link with the bundle id is the one `settings-general` names (Unverified 2 there); without a bundle id, the
    /// Notifications pane.
    func openNotificationSettings() {
        var link = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let id = Bundle.main.bundleIdentifier {
            link += "?id=\(id)"
        }
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Registers the banners' categories and their actions, in a fixed order, at launch.
    static func registerBannerCategories() {
        guard canNotify else {
            return
        }
        let categories = AlertContent.BannerCategory.allCases.map { category in
            UNNotificationCategory(
                identifier: category.rawValue,
                actions: BannerPayload.actions(of: category).map { action in
                    UNNotificationAction(
                        identifier: action.rawValue, title: action.title, options: [],
                        icon: UNNotificationActionIcon(systemImageName: icon(of: action)))
                },
                intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: hiddenPreviewsPlaceholder,
                options: [])
        }
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories + [inboxCategory(), inboxCategory(InboxBanner.coffeeCategory, actions: InboxBanner.coffeeActions)]))
    }

    /// The category of an Inbox event's banner: Show, Mark Done and Snooze 1 Hour.
    private static func inboxCategory(_ identifier: String = InboxBanner.category, actions: [InboxDeliveryAction] = InboxBanner.actions)
        -> UNNotificationCategory
    {
        UNNotificationCategory(
            identifier: identifier,
            actions: actions.map { action in
                UNNotificationAction(
                    identifier: InboxBanner.identifier(of: action),
                    title: identifier == InboxBanner.coffeeCategory && action == .done ? "On My Way ☕" : action.bannerTitle, options: [],
                    icon: UNNotificationActionIcon(systemImageName: inboxIcon(of: action)))
            },
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "MegaMonitor",
            options: [])
    }

    private static func inboxIcon(of action: InboxDeliveryAction) -> String {
        switch action {
        case .show: "arrow.up.forward.app"
        case .done: "checkmark.circle"
        case .snooze: "moon.zzz"
        case .dismiss: "xmark"
        }
    }

    /// The symbol of a banner action.
    private static func icon(of action: AlertContent.Action) -> String {
        switch action {
        case .openMergeRequest: "arrow.triangle.pull"
        case .rebuild: "arrow.clockwise"
        case .openConsole: "terminal"
        case .hide: "eye.slash"
        case .openBuild, .dismiss: "hammer"
        }
    }

    private func post(_ alert: BuildAlert) async -> Bool {
        guard await bannersAllowed() else {
            return false
        }
        let payload = BannerPayload(content: alert.content)
        let content = UNMutableNotificationContent()
        content.title = alert.content.headline
        content.subtitle = alert.content.project ?? ""
        content.body = alert.content.bannerBody
        content.categoryIdentifier = payload.category.rawValue
        content.userInfo = payload.userInfo
        content.threadIdentifier = alert.build.job
        // No sound of its own: playSound plays the result's sound once, in both styles (ALERT-02).
        content.sound = nil
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil))
            return true
        } catch {
            AppLog.warning("The banner of \(alert.build.id) didn't post: \(error.localizedDescription)")
            return false
        }
    }
}
