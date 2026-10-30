import AppKit
import Testing

@testable import MenubarUI

@Suite("Navigation input")
@MainActor
struct NavigationInputTests {
    typealias Decoder = NavigationInputDecoder

    @Test("WIN-08 the side buttons go back and forward once per click, however the mouse reports it")
    func decodesSideButtons() {
        var decoder = Decoder()
        #expect(decoder.request(for: .mouseButton(2, time: 1)) == nil)
        #expect(decoder.request(for: .mouseButton(3, time: 2)) == .back)
        // the same click's systemDefined events (press, release) come after it
        #expect(decoder.request(for: .auxButtons(changed: 8, state: 8, time: 2.002)) == nil)
        #expect(decoder.request(for: .auxButtons(changed: 8, state: 0, time: 2.1)) == nil)
        #expect(decoder.request(for: .mouseButton(4, time: 3)) == .forward)

        // a mouse that sends only the systemDefined event: the press acts, the release and the left button don't
        var auxOnly = Decoder()
        #expect(auxOnly.request(for: .auxButtons(changed: 8, state: 8, time: 5)) == .back)
        #expect(auxOnly.request(for: .auxButtons(changed: 8, state: 0, time: 5.1)) == nil)
        #expect(auxOnly.request(for: .auxButtons(changed: 1, state: 1, time: 5.2)) == nil)
        #expect(auxOnly.request(for: .auxButtons(changed: 16, state: 16, time: 6)) == .forward)
        // a second click later is a second step
        #expect(auxOnly.request(for: .auxButtons(changed: 16, state: 16, time: 7)) == .forward)
    }

    @Test("WIN-08 ⌘← and ⌘→ navigate unless text is being edited or another modifier is down")
    func decodesKeys() {
        var decoder = Decoder()
        #expect(decoder.request(for: .key(code: 123, modifiers: .command, isEditingText: false)) == .back)
        #expect(decoder.request(for: .key(code: 124, modifiers: .command, isEditingText: false)) == .forward)
        #expect(decoder.request(for: .key(code: 123, modifiers: .command, isEditingText: true)) == nil)
        #expect(decoder.request(for: .key(code: 123, modifiers: [.command, .shift], isEditingText: false)) == nil)
        #expect(decoder.request(for: .key(code: 123, modifiers: [], isEditingText: false)) == nil)
    }

    /// The bug of 2026-10-30: reading `keyCode` of a mouse event raises, so the side buttons never got as far as their
    /// button number. A real `otherMouseDown` of button 3 has to read without raising.
    @Test("WIN-08 an otherMouseDown of button 3 and a keyDown read for their own values only")
    func readsEventsByType() throws {
        let mouse = try #require(CGEvent(
            mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
        mouse.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        let mouseEvent = try #require(NSEvent(cgEvent: mouse))
        #expect(NavigationInput.input(from: mouseEvent) == .mouseButton(3, time: mouseEvent.timestamp))

        let key = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123))
        #expect(NavigationInput.input(from: key) == .key(code: 123, modifiers: .command, isEditingText: false))
    }
}
