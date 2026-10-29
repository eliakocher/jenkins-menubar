import Foundation

/// A folder of its own for one test, in the system's temporary folder, deleted with everything in it when the value
/// goes away.
///
/// Tests keep it in a local constant, so it lives until the test ends:
///
/// ```swift
/// let folder = try TemporaryFolder()
/// let store = FileStore(url: folder.file("state.json"), report: { _ in })
/// ```
final class TemporaryFolder: Sendable {
    /// the folder, which exists and is empty at first
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "menubar-monitor-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Returns the URL of a file or folder in this folder, without creating it.
    ///
    /// - Parameter path: a relative path, which may contain `/`
    /// - Returns: the URL inside this folder
    func file(_ path: String) -> URL {
        url.appending(path: path, directoryHint: .notDirectory)
    }

    /// Writes text into a file in this folder, creating the folders on its path.
    ///
    /// - Parameters:
    ///   - text: the file's content, written as UTF-8
    ///   - path: a relative path, which may contain `/`
    /// - Returns: the URL of the file
    @discardableResult
    func write(_ text: String, to path: String) throws -> URL {
        let file = file(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    /// Reads a file in this folder as UTF-8 text.
    ///
    /// - Parameter path: a relative path, which may contain `/`
    /// - Returns: the file's content
    func read(_ path: String) throws -> String {
        try String(contentsOf: file(path), encoding: .utf8)
    }

    /// Lists the files in this folder, recursively, as sorted relative paths. Folders are left out.
    ///
    /// - Returns: the relative paths, like `["caches/default/jenkins.json", "state.json"]`
    func contents() -> [String] {
        // The temporary folder is under /var, a symlink to /private/var, and the enumerator may resolve it.
        let base = url.resolvingSymlinksInPath().path(percentEncoded: false)
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { $0.resolvingSymlinksInPath().path(percentEncoded: false) }
            .map { $0.hasPrefix(base) ? String($0.dropFirst(base.count)) : $0 }
            .map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
            .sorted()
    }
}

/// A UserDefaults suite of its own for one test, removed when the value goes away.
///
/// The suite's name is unique, so tests that run in parallel never share values, and the app's own defaults
/// (`local.menubar-monitor`) are never touched.
final class TemporaryDefaults: @unchecked Sendable {
    /// the suite's name, like `menubar-monitor-tests.<UUID>`
    let suiteName: String
    /// the suite, empty at first
    let defaults: UserDefaults

    init() {
        suiteName = "menubar-monitor-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
