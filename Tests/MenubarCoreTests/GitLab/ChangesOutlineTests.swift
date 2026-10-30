import Testing

@testable import MenubarCore

/// How the Changes card groups, folds and draws its files (MR-11).
@Suite("Changes outline")
struct ChangesOutlineTests {
    private static func files(_ paths: [String]) -> [MergeRequestChanges.FileChange] {
        paths.map { MergeRequestChanges.FileChange(oldPath: $0, newPath: $0, kind: .modified, content: .empty) }
    }

    @Test(
        "MR-11 folders start folded when there is more than one, and a lone folder or a short list stays open",
        arguments: [
            (["a/1", "a/2", "b/3", "b/4", "c/5"], false, false),
            (["a/1", "a/2", "b/3", "b/4", "c/5", "c/6"], true, true),
            (["a/1", "a/2", "a/3", "a/4", "a/5", "a/6", "a/7"], true, false),
        ])
    func foldsFolders(paths: [String], grouped: Bool, folded: Bool) {
        let files = Self.files(paths)
        #expect(ChangesOutline.isGrouped(files) == grouped)
        #expect(ChangesOutline.startsFolded(files) == folded)
    }

    @Test("MR-11 a folded folder hides its files, and a filter opens every folder")
    func foldedRows() {
        let files = Self.files(["a/1", "a/2", "b/3", "b/4", "c/5", "c/6"])
        let folded = ChangesOutline.rows(of: files) { _ in true }
        #expect(folded.count == 3)
        let filtered = ChangesOutline.rows(of: files, filter: "3") { _ in true }
        #expect(filtered.count == 2)
    }

    @Test(
        "MR-11 the stat blocks grow with the change and split by additions and deletions",
        arguments: [
            (0, 0, 0, 0), (1, 0, 1, 0), (0, 1, 0, 1), (408, 16, 4, 1), (400, 100, 4, 1), (3, 3, 1, 1), (1, 1, 1, 0),
            (50, 50, 3, 2), (2, 0, 1, 0), (30, 2, 3, 1),
        ])
    func blocks(additions: Int, deletions: Int, green: Int, red: Int) {
        let blocks = DiffStatBlocks.blocks(additions: additions, deletions: deletions)
        #expect(blocks.count == 5)
        #expect(blocks.filter { $0 == .added }.count == green)
        #expect(blocks.filter { $0 == .removed }.count == red)
        // Green first, then red, then the empty ones.
        #expect(blocks == blocks.sorted { $0.order < $1.order })
    }

    @Test("MR-11 a tiny change fills fewer blocks than a big one")
    func scale() {
        func filled(_ total: Int) -> Int {
            DiffStatBlocks.blocks(additions: total, deletions: 0).count { $0 != .none }
        }
        #expect([1, 4, 10, 100, 100_000].map(filled) == [1, 2, 3, 5, 5])
    }

    @Test("MR-11 a common start of the folders shows once, and a long path is cut at a slash from the left")
    func prefixAndVariants() {
        #expect(
            ChangesOutline.commonPrefix(of: ["qa/src/a/", "qa/src/b/", "qa/src/b/deep/"]) == "qa/src/")
        #expect(ChangesOutline.commonPrefix(of: ["qa/src/", "app/"]) == "")
        #expect(ChangesOutline.commonPrefix(of: ["qa/src/"]) == "")
        #expect(
            ChangesOutline.pathVariants(of: "a/b/c/d/") == ["a/b/c/d/", "…/b/c/d/", "…/c/d/", "…/d/"])
        #expect(ChangesOutline.pathVariants(of: "") == [""])
    }
}

private extension DiffStatBlocks.Block {
    var order: Int {
        switch self {
        case .added: 0
        case .removed: 1
        case .none: 2
        }
    }
}
