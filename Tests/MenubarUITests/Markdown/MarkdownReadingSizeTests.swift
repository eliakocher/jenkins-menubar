import Testing

@testable import MenubarUI

/// The reading size's steps (WIN-02): never outside the list, whatever an old or edited preference holds.
@Suite("MarkdownReadingSize")
struct MarkdownReadingSizeTests {
    @Test(
        "WIN-02 the reading size steps stay inside 0.85× to 2× and reset to 1×",
        arguments: [
            (start: 1, change: 1, expected: 2), (start: 6, change: 1, expected: 6), (start: 0, change: -1, expected: 0),
            (start: 4, change: 0, expected: 1), (start: 99, change: 0, expected: 1), (start: 99, change: -1, expected: 5),
            (start: -3, change: 1, expected: 1),
        ])
    func steps(start: Int, change: Int, expected: Int) {
        #expect(MarkdownReadingSize.step(start, changedBy: change) == expected)
    }
}
