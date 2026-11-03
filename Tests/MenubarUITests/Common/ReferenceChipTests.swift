import SwiftUI
import Testing

@testable import MenubarUI

/// The one look of work item and merge request references: blue "#", green "!".
@Suite("Reference chips")
struct ReferenceChipTests {
    @Test("WI-05 a reference's tooltip is its number, the state when there is one, and the title; the colour never says the state")
    func tooltips() {
        #expect(ReferenceKind.tooltip("!12404", state: "merged", title: "Rework the tokens") == "!12404 · merged · Rework the tokens")
        #expect(ReferenceKind.tooltip("#18874", title: "Dialog answers twice") == "#18874 · Dialog answers twice")
        #expect(ReferenceKind.tooltip("!12", state: "", title: nil) == "!12")
        #expect(ReferenceKind.workItem.tint == Color.blue)
        #expect(ReferenceKind.mergeRequest.tint != ReferenceKind.workItem.tint)
    }
}
