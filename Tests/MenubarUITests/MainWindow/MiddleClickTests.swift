import AppKit
import Testing

@testable import MenubarUI

@Suite("Middle click")
@MainActor
struct MiddleClickTests {
    @Test("WIN-06 events of other types are read without raising: only mouse buttons have a button number")
    func readsOnlyWhatTheTypeHas() throws {
        let key = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(!MiddleClick.isMiddleClick(key))
        let left = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0))
        #expect(!MiddleClick.isMiddleClick(left))
    }
}
