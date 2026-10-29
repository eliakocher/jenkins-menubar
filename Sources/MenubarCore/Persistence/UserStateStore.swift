import Foundation

/// Keeps the ``UserState`` of every project in `state.json` in Application Support.
public struct UserStateStore: Sendable {
    /// the version ``UserStateStore`` writes
    public static let formatVersion = 1

    private let file: FileStore<StateFile>

    /// Creates the store. Nothing is read yet.
    ///
    /// - Parameters:
    ///   - folder: the Application Support folder (``FileLocations/applicationSupport``)
    ///   - report: called when `state.json` is corrupt
    public init(folder: URL, report: @escaping @Sendable (String) -> Void) {
        file = FileStore(url: folder.appending(path: "state.json", directoryHint: .notDirectory), report: report)
    }

    /// the file
    public var url: URL { file.url }

    /// Reads a project's state.
    ///
    /// - Parameter project: the project
    /// - Returns: its state; empty when nothing is stored for it
    public func load(_ project: ProjectID) -> UserState {
        file.load()?.projects[project] ?? UserState()
    }

    /// Writes a project's state, keeping the other projects' states.
    ///
    /// - Parameters:
    ///   - state: the state
    ///   - project: the project
    public func save(_ state: UserState, for project: ProjectID) throws {
        var contents = file.load() ?? StateFile(formatVersion: Self.formatVersion, projects: [:])
        contents.formatVersion = Self.formatVersion
        contents.projects[project] = state
        try file.save(contents)
    }

    /// Reads a project's state, changes it and writes it back.
    ///
    /// - Parameters:
    ///   - project: the project
    ///   - change: changes the state
    /// - Returns: the changed state
    @discardableResult
    public func update(_ project: ProjectID, _ change: (inout UserState) -> Void) throws -> UserState {
        var state = load(project)
        change(&state)
        try save(state, for: project)
        return state
    }

    /// Forgets a removed project's state, keeping the others' (PROJ-02).
    ///
    /// - Parameter project: the project
    public func remove(_ project: ProjectID) throws {
        guard var contents = file.load(), contents.projects[project] != nil else {
            return
        }
        contents.projects[project] = nil
        try file.save(contents)
    }

    struct StateFile: Codable, Sendable {
        var formatVersion: Int
        var projects: [ProjectID: UserState]
    }
}
