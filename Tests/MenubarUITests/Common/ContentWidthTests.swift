import Testing

@testable import MenubarUI

@Suite("ContentWidth")
struct ContentWidthTests {
    @Test(
        "WIN-02 the content width maps each option to its limit, Custom inside 800 to 2000, anything unknown to Full Width",
        arguments: [
            (stored: "full", custom: 1200.0, expected: nil), (stored: "wide", custom: 1200, expected: 1400),
            (stored: "comfortable", custom: 1200, expected: 1100), (stored: "custom", custom: 1250, expected: 1250),
            (stored: "custom", custom: 100, expected: 800), (stored: "custom", custom: 5000, expected: 2000),
            (stored: "huge", custom: 1200, expected: nil), (stored: "", custom: 1200, expected: nil),
        ] as [(stored: String, custom: Double, expected: Double?)])
    func points(stored: String, custom: Double, expected: Double?) {
        #expect(ContentWidth.points(stored: stored, custom: custom).map(Double.init) == expected)
    }
}
