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
    }

    @Test("APP-01 a window that reports twice counts once")
    func reportsTwice() {
        var presence = DockPresence()
        presence.opened("main")
        presence.opened("main")
        presence.closed("main")
        #expect(!presence.showsDockIcon)
        // A close without an open, as when a window closes before its content appeared, changes nothing.
        presence.closed("welcome")
        #expect(presence.openWindows.isEmpty)
    }
}
