import MenubarCore
import Testing

@testable import MenubarUI

@Suite("NotificationNotice")
struct NotificationNoticeTests {
    /// The permission, whether any row is a Banner, and the kind of row Settings → Notifications shows: nil for none.
    private static let cases: [(NotificationPermission?, Bool, StatusKind?)] = [
        (.off, true, .problem),
        (.notAsked, true, .note),
        // No row is a Banner, allowed, or not known yet: no row.
        (.off, false, nil),
        (.allowed, true, nil),
        (nil, true, nil),
    ]

    @Test("APP-04 Settings shows a denied or never asked permission while a row is a Banner", arguments: cases.indices)
    func showsThePermission(_ index: Int) {
        let (permission, usesBanners, kind) = Self.cases[index]
        // By default the builds I watch are banners; with none, they are Inbox entries.
        var preferences = Preferences()
        if !usesBanners {
            preferences.inboxNotifications.set(.inbox, for: .watchedBuildFailed)
            preferences.inboxNotifications.set(.inbox, for: .watchedBuildSucceeded)
        }

        let notice = NotificationNotice.of(permission, preferences: preferences)

        #expect(notice?.kind == kind)
    }
}
