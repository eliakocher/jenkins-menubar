import Testing

@testable import MenubarCore

/// Which slot cards are open (SLOT-15).
@Suite("Slot expansion")
struct SlotExpansionTests {
    @Test("SLOT-15 a click is remembered by the slot's name, and a click back to the default forgets it")
    func remembered() {
        var expansion = SlotExpansion()
        // untouched, the current slot is open and the others are closed
        #expect(expansion.isExpanded(name: "2026.45", state: .current))
        #expect(!expansion.isExpanded(name: "2026.44", state: .overdue))
        expansion = expansion.toggled(name: "2026.48", state: .upcoming)
        #expect(expansion.isExpanded(name: "2026.48", state: .upcoming))
        expansion = expansion.toggled(name: "2026.45", state: .current)
        #expect(!expansion.isExpanded(name: "2026.45", state: .current))
        // what the user chose stays when the slot's state moves on: 2026.45 is released now and stays closed, 2026.48 is the
        // current one and stays open
        #expect(!expansion.isExpanded(name: "2026.45", state: .released))
        #expect(expansion.isExpanded(name: "2026.48", state: .current))
        // a click back to the default leaves nothing remembered, so the slot follows the default again
        let back = expansion.toggled(name: "2026.48", state: .upcoming).toggled(name: "2026.45", state: .current)
        #expect(back == SlotExpansion())
        #expect(back.isExpanded(name: "2026.45", state: .current) && !back.isExpanded(name: "2026.48", state: .upcoming))
    }

    @Test("SLOT-15 the choices round-trip through the setting; nonsense is dropped")
    func settingText() {
        let expansion = SlotExpansion().toggled(name: "2026.48", state: .upcoming).toggled(name: "2026.45", state: .current)
            .toggled(name: "odd, name%", state: .overdue)
        #expect(SlotExpansion(id: expansion.id) == expansion)
        #expect(expansion.id == "+2026.48,+odd%2C name%25,-2026.45")
        #expect(SlotExpansion(id: "").id.isEmpty)
        #expect(SlotExpansion(id: "x,+,-,2026.45,+2026.48") == SlotExpansion(opened: ["2026.48"]))
    }
}
