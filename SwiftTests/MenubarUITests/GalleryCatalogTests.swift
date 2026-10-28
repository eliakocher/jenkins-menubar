import Testing

@testable import MenubarUI

@Suite("GalleryCatalog")
struct GalleryCatalogTests {
    @Test("every entry has a unique id, slugs without dots or spaces, and a size")
    func entriesAreWellFormed() {
        let entries = GalleryCatalog.entries

        #expect(!entries.isEmpty)
        #expect(Set(entries.map(\.id)).count == entries.count)
        for entry in entries {
            #expect(entry.screen.wholeMatch(of: /[a-z0-9-]+/) != nil, "screen \(entry.screen)")
            #expect(entry.state.wholeMatch(of: /[a-z0-9-]+/) != nil, "state \(entry.state)")
            #expect(entry.size.width > 0 && entry.size.height > 0, "size of \(entry.id)")
        }
    }
}
