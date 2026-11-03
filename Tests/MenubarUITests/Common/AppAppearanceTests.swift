import AppKit
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("AppAppearance")
@MainActor
struct AppAppearanceTests {
    @Test("SET-01 automatic leaves the app's appearance to macOS, light and dark force Aqua and Dark Aqua")
    func mapping() {
        #expect(AppAppearance.nsAppearance(for: .system) == nil)
        #expect(AppAppearance.nsAppearance(for: .light)?.name == .aqua)
        #expect(AppAppearance.nsAppearance(for: .dark)?.name == .darkAqua)
    }
}
