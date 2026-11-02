import Testing

@testable import MenubarCore

/// How the Changes card groups and folds its files (MR-11).
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
}
