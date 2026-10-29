import MenubarCore
import SwiftUI

/// The pane's easter eggs (`docs/easter-eggs.md`): the Konami code's keys, and the Quit row's title while Option is held.
extension MenuPaneView {
    /// the keys the pane handles: its own, and B and A of the Konami code
    static let handledKeys: Set<KeyEquivalent> = [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .escape, "b", "a"]

    /// Returns the Konami key of a pressed key.
    ///
    /// - Parameter key: the key
    /// - Returns: the key of the code; `nil` for any other
    static func konamiKey(_ key: KeyEquivalent) -> KonamiKey? {
        switch key {
        case .upArrow: .up
        case .downArrow: .down
        case .leftArrow: .left
        case .rightArrow: .right
        case "b": .b
        case "a": .a
        default: nil
        }
    }
}
