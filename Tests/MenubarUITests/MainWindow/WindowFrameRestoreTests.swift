import Foundation
import Testing

@testable import MenubarUI

@Suite("Window frame restore")
struct WindowFrameRestoreTests {
    private let main = CGRect(x: 0, y: 0, width: 1728, height: 1000)
    private let side = CGRect(x: 1728, y: 0, width: 1920, height: 1080)
    private let size = CGSize(width: 1120, height: 720)

    @Test("WIN-01 a saved frame on a screen stays, one on a gone display falls back to the default size, centered")
    func restoresOrFallsBack() {
        let onMain = CGRect(x: 100, y: 80, width: 900, height: 600)
        #expect(WindowFrameRestore.frame(restored: onMain, screens: [main, side], defaultSize: size) == onMain)
        let onSide = CGRect(x: 2000, y: 100, width: 800, height: 500)
        #expect(WindowFrameRestore.frame(restored: onSide, screens: [main, side], defaultSize: size) == onSide)
        // the side display was unplugged
        let fallback = WindowFrameRestore.frame(restored: onSide, screens: [main], defaultSize: size)
        #expect(fallback == CGRect(x: 304, y: 140, width: 1120, height: 720))
    }
}
