import MenubarCore
import Testing

@testable import MenubarUI

@Suite("NotificationNotice")
struct NotificationNoticeTests {
    /// The permission, the alert style and the stage banners, and the kind of row Settings → General shows: nil for none.
    private static let cases: [(NotificationPermission?, Preferences.AlertStyle, Bool, StatusKind?)] = [
        (.off, .banner, true, .problem),
        (.notAsked, .window, true, .note),
        // Banners not in use, allowed, or not known yet: no row.
        (.off, .window, false, nil),
        (.allowed, .banner, true, nil),
        (nil, .banner, true, nil),
    ]

    @Test("APP-04 Settings shows a denied or never asked permission", arguments: cases.indices)
    func showsThePermission(_ index: Int) {
        let (permission, style, stageBanners, kind) = Self.cases[index]
        var preferences = Preferences()
        preferences.alertStyle = style
        preferences.stageAlerts = stageBanners

        let notice = NotificationNotice.of(permission, preferences: preferences)

        #expect(notice?.kind == kind)
    }
}
