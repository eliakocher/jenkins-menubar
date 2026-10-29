import Foundation

/// The folders the app keeps its files in, from the identity map of the plan.
///
/// Normally they are in `~/Library`. When `MENUBAR_MONITOR_DATA_DIR` names a folder, all three are in it instead, so
/// the smoke check and other runs of the built app never touch the user's files.
public struct FileLocations: Hashable, Sendable {
    /// the variable that moves every folder, for the smoke check
    public static let dataDirectoryVariable = "MENUBAR_MONITOR_DATA_DIR"

    /// `~/Library/Application Support/menubar-monitor`: the projects and the watched and hidden builds
    public var applicationSupport: URL
    /// `~/Library/Caches/menubar-monitor`: one folder per project
    public var caches: URL
    /// `~/Library/Logs/menubar-monitor`: the activity log, the check times and the captured requests
    public var logs: URL

    public init(applicationSupport: URL, caches: URL, logs: URL) {
        self.applicationSupport = applicationSupport
        self.caches = caches
        self.logs = logs
    }

    /// Creates the locations inside one folder: `Application Support`, `Caches` and `Logs`.
    ///
    /// - Parameter root: the folder, like a test's temporary folder
    public init(root: URL) {
        self.init(
            applicationSupport: root.appending(path: "Application Support", directoryHint: .isDirectory),
            caches: root.appending(path: "Caches", directoryHint: .isDirectory),
            logs: root.appending(path: "Logs", directoryHint: .isDirectory))
    }

    /// Returns the app's locations: in `MENUBAR_MONITOR_DATA_DIR` when it is set and not empty, otherwise in
    /// `~/Library`.
    ///
    /// - Parameters:
    ///   - environment: the process environment
    ///   - library: the user's Library folder
    /// - Returns: the locations
    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        library: URL = URL.libraryDirectory
    ) -> FileLocations {
        if let root = environment[dataDirectoryVariable], !root.isEmpty {
            return FileLocations(root: URL(filePath: root, directoryHint: .isDirectory).standardizedFileURL)
        }
        return FileLocations(
            applicationSupport: library.appending(path: "Application Support/\(AppIdentity.name)", directoryHint: .isDirectory),
            caches: library.appending(path: "Caches/\(AppIdentity.name)", directoryHint: .isDirectory),
            logs: library.appending(path: "Logs/\(AppIdentity.name)", directoryHint: .isDirectory))
    }

    /// Returns the caches folder of a project, `~/Library/Caches/menubar-monitor/<ProjectID>`.
    ///
    /// - Parameter project: the project
    /// - Returns: the folder
    public func caches(for project: ProjectID) -> URL {
        caches.appending(path: project.rawValue, directoryHint: .isDirectory)
    }
}
