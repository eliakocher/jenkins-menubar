import Foundation

/// A cached answer: the value, when it was fetched, and the problem of the last attempt.
///
/// When a load fails, the store keeps the last value and its `fetchedAt`, and sets `problem`; the views show both
/// (OD-01, MR-05).
public struct Cached<Value: Codable & Sendable>: Codable, Sendable {
    public var value: Value
    /// when the value was fetched
    public var fetchedAt: Date
    /// the problem of the last attempt; `nil` when it worked
    public var problem: Problem?

    public init(value: Value, fetchedAt: Date, problem: Problem? = nil) {
        self.value = value
        self.fetchedAt = fetchedAt
        self.problem = problem
    }
}

extension Cached: Equatable where Value: Equatable {}
extension Cached: Hashable where Value: Hashable {}

/// The name of a cache file and the type of the value it holds.
///
/// The feature that owns a cache adds its file as a static member in an extension, like ``mergeRequests``:
///
/// ```swift
/// extension CacheFile where Value == JenkinsState {
///     static var jenkins: CacheFile { CacheFile("jenkins") }
/// }
/// ```
public struct CacheFile<Value: Codable & Sendable>: Hashable, Sendable {
    /// the file name without `.json`, like `merged-merge-requests`
    public let name: String

    /// Creates a cache file name.
    ///
    /// - Parameter name: lowercase ASCII letters, digits and `-`, unique among the caches of a project
    public init(_ name: String) {
        precondition(
            !name.isEmpty && name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" },
            "a cache file name is lowercase letters, digits and -")
        self.name = name
    }
}

extension CacheFile where Value == [Int] {
    /// the iids of the merged MRs among the MR jobs (HIDE-03)
    public static var mergedMergeRequests: CacheFile { CacheFile("merged-merge-requests") }
}

/// Keeps the cached answers of every project, each in its own file in the project's caches folder,
/// `~/Library/Caches/menubar-monitor/<ProjectID>/<name>.json`.
///
/// Caches can be thrown away at any time: a missing or corrupt file just means the next load starts from nothing.
public struct CacheStore: Sendable {
    private let folder: URL
    private let report: @Sendable (String) -> Void

    /// Creates the store. Nothing is read yet.
    ///
    /// - Parameters:
    ///   - folder: the caches folder (``FileLocations/caches``)
    ///   - report: called when a cache file is corrupt
    public init(folder: URL, report: @escaping @Sendable (String) -> Void) {
        self.folder = folder
        self.report = report
    }

    /// Returns the folder of a project's caches.
    ///
    /// - Parameter project: the project
    /// - Returns: the folder, `<caches>/<ProjectID>`
    public func folder(for project: ProjectID) -> URL {
        folder.appending(path: project.rawValue, directoryHint: .isDirectory)
    }

    /// Returns the URL of a cache file.
    ///
    /// - Parameters:
    ///   - file: the cache file
    ///   - project: the project
    /// - Returns: the URL, `<caches>/<ProjectID>/<name>.json`
    public func url<Value>(of file: CacheFile<Value>, for project: ProjectID) -> URL {
        folder(for: project).appending(path: "\(file.name).json", directoryHint: .notDirectory)
    }

    /// Reads a cached answer.
    ///
    /// - Parameters:
    ///   - file: the cache file
    ///   - project: the project
    /// - Returns: the cached answer, or `nil` when there is none or the file is corrupt
    public func load<Value>(_ file: CacheFile<Value>, for project: ProjectID) -> Cached<Value>? {
        store(file, project).load()
    }

    /// Writes a cached answer.
    ///
    /// - Parameters:
    ///   - cached: the answer
    ///   - file: the cache file
    ///   - project: the project
    public func save<Value>(_ cached: Cached<Value>, as file: CacheFile<Value>, for project: ProjectID) throws {
        try store(file, project).save(cached)
    }

    /// Deletes a cached answer, like the GitLab data when the GitLab token is removed (MR-04).
    ///
    /// - Parameters:
    ///   - file: the cache file
    ///   - project: the project
    public func delete<Value>(_ file: CacheFile<Value>, for project: ProjectID) throws {
        try store(file, project).delete()
    }

    /// Deletes every cache file of a project.
    ///
    /// - Parameter project: the project
    public func deleteAll(for project: ProjectID) throws {
        do {
            try FileManager.default.removeItem(at: folder(for: project))
        } catch CocoaError.fileNoSuchFile {
        }
    }

    private func store<Value>(_ file: CacheFile<Value>, _ project: ProjectID) -> FileStore<Cached<Value>> {
        FileStore(url: url(of: file, for: project), report: report)
    }
}
