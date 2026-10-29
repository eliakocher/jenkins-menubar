import Foundation

/// The fixture files in `Tests/Fixtures/`: sanitized real answers of Jenkins and GitLab, and copies of the old
/// tool's files. They sit outside the test targets, so SwiftPM doesn't ask to declare them as resources.
///
/// ```swift
/// let jobs = try FixtureFiles.data("Jenkins/jobs.json")
/// ```
enum FixtureFiles {
    /// `Tests/Fixtures/`, found from this file's place in the checkout
    static let folder = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures", directoryHint: .isDirectory)

    /// Returns the URL of a fixture, without reading it.
    ///
    /// - Parameter path: a path relative to `Tests/Fixtures/`, such as `Jenkins/jobs.json`
    /// - Returns: the URL of the fixture
    static func url(_ path: String) -> URL {
        folder.appending(path: path, directoryHint: .notDirectory)
    }

    /// Reads a fixture.
    ///
    /// - Parameter path: a path relative to `Tests/Fixtures/`
    /// - Returns: the fixture's bytes
    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }

    /// Reads a fixture as UTF-8 text.
    ///
    /// - Parameter path: a path relative to `Tests/Fixtures/`
    /// - Returns: the fixture's text
    static func string(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }
}
