import Foundation

/// Keeps the projects in `projects.json` in Application Support, and passes the team values to colleagues in a team
/// file (TEAM-02).
///
/// v1 has one project: ``primaryProject()`` is the first stored project, or an empty ``ProjectID/main``.
public struct TeamStore: Sendable {
    /// the version ``TeamStore`` writes, in `projects.json` and in team files
    public static let formatVersion = 1

    private let file: FileStore<ProjectsFile>

    /// Creates the store. Nothing is read yet.
    ///
    /// - Parameters:
    ///   - folder: the Application Support folder (``FileLocations/applicationSupport``)
    ///   - report: called when `projects.json` is corrupt
    public init(folder: URL, report: @escaping @Sendable (String) -> Void) {
        file = FileStore(url: folder.appending(path: "projects.json", directoryHint: .notDirectory), report: report)
    }

    /// the file
    public var url: URL { file.url }

    /// Reads the projects.
    ///
    /// - Returns: the stored projects, in the order they were added; empty when none is stored
    public func projects() -> [Project] {
        file.load()?.projects ?? []
    }

    /// Reads the primary project.
    ///
    /// - Returns: the first stored project, or ``ProjectID/main`` with empty team values (TEAM-03)
    public func primaryProject() -> Project {
        projects().first ?? Project(id: .main, team: TeamValues())
    }

    /// Reads one project.
    ///
    /// - Parameter id: the project's id
    /// - Returns: the stored project; the primary one when the id is the primary's, even before it is stored; `nil`
    ///   for an id no project has
    public func project(_ id: ProjectID) -> Project? {
        let primary = primaryProject()
        return id == primary.id ? primary : projects().first { $0.id == id }
    }

    /// Adds a project after the others, with a new id (PROJ-02).
    ///
    /// - Parameter team: its team values, normalized as TEAM-01 saves them
    /// - Returns: the added project
    /// - Throws: a ``ProjectError`` when the values are incomplete, the job is watched already, or the servers aren't
    ///   the primary project's
    @discardableResult
    public func add(_ team: TeamValues) throws -> Project {
        let team = team.normalized()
        if let refusal = ProjectError.refusal(of: team, among: projects()) {
            throw refusal
        }
        let project = Project(id: .random(), team: team)
        try save(project)
        return project
    }

    /// Removes a project that isn't the primary one (PROJ-02). Its watched and hidden builds and caches are the
    /// caller's to delete.
    ///
    /// - Parameter id: the project's id
    /// - Throws: ``ProjectError/primary`` for the primary project, or the error of saving
    public func remove(_ id: ProjectID) throws {
        var projects = projects()
        guard id != projects.first?.id else {
            throw ProjectError.primary
        }
        projects.removeAll { $0.id == id }
        try file.save(ProjectsFile(formatVersion: Self.formatVersion, projects: projects))
    }

    /// Writes a project, in the place of the stored one with its id, or after the others.
    ///
    /// - Parameter project: the project
    public func save(_ project: Project) throws {
        var projects = projects()
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        try file.save(ProjectsFile(formatVersion: Self.formatVersion, projects: projects))
    }

    /// Writes a project's team values to a team file: JSON with a format version and the team values only.
    ///
    /// - Parameters:
    ///   - id: the project; the primary one by default
    ///   - url: the file, which is replaced
    public func exportTeamFile(of id: ProjectID? = nil, to url: URL) throws {
        let team = id.flatMap(project)?.team ?? primaryProject().team
        let data = try JSONCoding.encoder.encode(TeamFile(formatVersion: Self.formatVersion, team: team))
        try data.write(to: url, options: .atomic)
    }

    /// Reads a team file into a project and saves it. The values are normalized as TEAM-01 saves them.
    ///
    /// - Parameters:
    ///   - url: the team file
    ///   - id: the project; the primary one by default
    /// - Returns: the project with the imported values
    /// - Throws: a ``TeamFileError`` that says why the file was refused, a ``ProjectError`` when another project's
    ///   values don't fit the primary's servers, or the error of saving
    @discardableResult
    public func importTeamFile(from url: URL, into id: ProjectID? = nil) throws -> Project {
        var project = id.flatMap(project) ?? primaryProject()
        project.team = try Self.readTeamFile(from: url)
        if project.id != primaryProject().id,
           let refusal = ProjectError.refusal(of: project.team, among: projects().filter { $0.id != project.id }) {
            throw refusal
        }
        try save(project)
        return project
    }

    /// Reads a team file without importing it.
    ///
    /// - Parameter url: the team file
    /// - Returns: its team values, normalized as TEAM-01 saves them
    /// - Throws: a ``TeamFileError`` that says why the file was refused
    public static func readTeamFile(from url: URL) throws -> TeamValues {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TeamFileError.unreadable(error.localizedDescription)
        }
        // The version is read first, so a newer file is refused for its version and not for its shape.
        guard let header = try? JSONCoding.decoder.decode(TeamFileHeader.self, from: data) else {
            throw TeamFileError.notATeamFile
        }
        guard header.formatVersion <= formatVersion else {
            throw TeamFileError.newerFormat(header.formatVersion)
        }
        guard let teamFile = try? JSONCoding.decoder.decode(TeamFile.self, from: data) else {
            throw TeamFileError.notATeamFile
        }
        return teamFile.team.normalized()
    }

    struct ProjectsFile: Codable, Sendable {
        var formatVersion: Int
        var projects: [Project]
    }

    /// The team file: `{"formatVersion": 1, "team": {…}}`.
    struct TeamFile: Codable, Sendable {
        var formatVersion: Int
        var team: TeamValues
    }

    private struct TeamFileHeader: Decodable {
        var formatVersion: Int
    }
}

/// Why a team file was refused (TEAM-02).
public enum TeamFileError: Error, Hashable, Sendable, LocalizedError {
    /// the file couldn't be read, with the system's reason
    case unreadable(String)
    /// the file isn't JSON with a format version and team values
    case notATeamFile
    /// the file was written by a newer menubar-monitor, with this format version
    case newerFormat(Int)

    /// the text Settings and the welcome flow show
    public var message: String {
        switch self {
        case .unreadable(let reason): "The team file could not be read: \(reason)"
        case .notATeamFile: "That is not a menubar-monitor team file"
        case .newerFormat(let version):
            "That team file is from a newer menubar-monitor (format \(version)): update the app first"
        }
    }

    public var errorDescription: String? { message }
}
