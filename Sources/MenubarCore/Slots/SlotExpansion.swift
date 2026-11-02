import Foundation

/// Which slot cards of the Slots section are open (SLOT-15). A slot the user never touched follows the default: the
/// current slot open, every other one closed. A click opens or closes a card; that choice is remembered by the slot's
/// name, and a click that brings a card back to its default forgets it again, so the card follows the default once more
/// (when the next slot becomes the current one, it opens by itself).
public struct SlotExpansion: Hashable, Sendable {
    /// the slots the user opened that the default keeps closed
    public private(set) var opened: Set<String>
    /// the slots the user closed that the default keeps open
    public private(set) var closed: Set<String>

    /// - Parameters:
    ///   - opened: the names of the slots the user opened
    ///   - closed: the names of the slots the user closed
    public init(opened: Set<String> = [], closed: Set<String> = []) {
        self.opened = opened.subtracting(closed)
        self.closed = closed
    }

    /// whether a slot is open when the user has not chosen: only the current one
    public static func isOpenByDefault(_ state: SlotState) -> Bool {
        state == .current
    }

    /// Returns whether a slot's card is open.
    ///
    /// - Parameters:
    ///   - name: the slot's name
    ///   - state: the slot's state
    public func isExpanded(name: String, state: SlotState) -> Bool {
        if opened.contains(name) { return true }
        if closed.contains(name) { return false }
        return Self.isOpenByDefault(state)
    }

    /// Returns the expansion with the slot's card set open or closed, as the user chose.
    ///
    /// - Parameters:
    ///   - expanded: whether the card is to be open
    ///   - name: the slot's name
    ///   - state: the slot's state
    public func setting(_ expanded: Bool, name: String, state: SlotState) -> SlotExpansion {
        var copy = self
        copy.opened.remove(name)
        copy.closed.remove(name)
        if expanded != Self.isOpenByDefault(state) {
            if expanded { copy.opened.insert(name) } else { copy.closed.insert(name) }
        }
        return copy
    }

    /// Returns the expansion after a click on the slot's header.
    public func toggled(name: String, state: SlotState) -> SlotExpansion {
        setting(!isExpanded(name: name, state: state), name: name, state: state)
    }

    // MARK: Remembered

    /// the setting's text: the opened names with `+`, the closed with `-`, sorted and separated by commas (a comma or a
    /// percent sign in a name is escaped)
    public var id: String {
        (opened.map { "+" + SlotChipSelection.escape($0) } + closed.map { "-" + SlotChipSelection.escape($0) })
            .sorted().joined(separator: ",")
    }

    /// Reads the setting; what isn't a `+name` or a `-name` is dropped.
    public init(id: String) {
        var opened: Set<String> = []
        var closed: Set<String> = []
        for part in id.split(separator: ",") where part.count > 1 {
            let name = SlotChipSelection.unescape(String(part.dropFirst()))
            switch part.first {
            case "+": opened.insert(name)
            case "-": closed.insert(name)
            default: break
            }
        }
        self.init(opened: opened, closed: closed)
    }
}
