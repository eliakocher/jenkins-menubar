import Testing

@testable import MenubarCore

@Suite("DockPresence")
struct DockPresenceTests {
    @Test("APP-01 a Dock icon while a window is open, none after the last one closes")
    func dockIcon() {
        var presence = DockPresence()
        #expect(!presence.showsDockIcon)
        presence.opened("main")
        #expect(presence.showsDockIcon)
        presence.opened("settings")
        presence.closed("main")
        #expect(presence.showsDockIcon)
        presence.closed("settings")
        #expect(!presence.showsDockIcon)
        presence.opened("main")
        #expect(presence.showsDockIcon)

        // A window that reports twice counts once, and a close without an open (a window that closes before its content
        // appeared) changes nothing.
        presence.opened("main")
        presence.closed("main")
        #expect(!presence.showsDockIcon)
        presence.closed("welcome")
        #expect(presence.openWindows.isEmpty)
    }
}
