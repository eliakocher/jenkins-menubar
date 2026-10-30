import MenubarCore
import Testing

@testable import MenubarUI

@Suite("NotificationNotice")
struct NotificationNoticeTests {
    /// The permission, the alert style and the stage banners, and the row Settings → General shows: nil for none.
    private static let cases: [(NotificationPermission?, Preferences.AlertStyle, Bool, StatusKind?, String?)] = [
        (.off, .banner, true, .problem,
         "Notifications are off for MegaMonitor: stage banners don't show, and banners show as the alert window"),
        (.off, .window, true, .problem, "Notifications are off for MegaMonitor: stage banners don't show"),
        (.off, .banner, false, .problem, "Notifications are off for MegaMonitor: banners show as the alert window"),
        (.notAsked, .window, true, .note, "Notifications aren't set up yet: stage banners can't show"),
        (.notAsked, .banner, false, .note, "Notifications aren't set up yet: banners show as the alert window"),
        // Banners not in use, allowed, or not known yet: no row.
        (.off, .window, false, nil, nil),
        (.notAsked, .window, false, nil, nil),
        (.allowed, .banner, true, nil, nil),
        (nil, .banner, true, nil, nil),
    ]

    @Test("APP-04 Settings shows a denied or never asked permission", arguments: cases.indices)
    func showsThePermission(_ index: Int) {
        let (permission, style, stageBanners, kind, text) = Self.cases[index]
        var preferences = Preferences()
        preferences.alertStyle = style
        preferences.stageAlerts = stageBanners

        let notice = NotificationNotice.of(permission, preferences: preferences)

        #expect(notice?.kind == kind)
        #expect(notice?.text == text)
        #expect(notice?.buttonTitle == kind.map { $0 == .problem ? "Open System Settings…" : "Turn On Notifications…" })
    }
}
