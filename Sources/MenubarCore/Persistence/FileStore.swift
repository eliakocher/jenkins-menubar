import Foundation

/// One JSON file that holds one Codable value, written atomically.
///
/// A missing file reads as `nil`. So does a file that can't be read or decoded: it counts as empty, is renamed to
/// `<name>.corrupt` so the next write doesn't destroy what it held, and is reported once through `report`.
public struct FileStore<Value: Codable & Sendable>: Sendable {
    /// the file
    public let url: URL
    private let report: @Sendable (String) -> Void

    /// Creates a store for one file. Nothing is read or written yet.
    ///
    /// - Parameters:
    ///   - url: the file; its folder is created on the first write
    ///   - report: called with a one-line message when the file is corrupt, for the activity log
    public init(url: URL, report: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.report = report
    }

    /// the file a corrupt file is moved to
    public var corruptURL: URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".corrupt", directoryHint: .notDirectory)
    }

    /// Reads the value.
    ///
    /// - Returns: the value, or `nil` when the file is missing or corrupt
    public func load() -> Value? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            setAside(because: error)
            return nil
        }
        do {
            return try JSONCoding.decoder.decode(Value.self, from: data)
        } catch {
            setAside(because: error)
            return nil
        }
    }

    /// Writes the value, replacing the file in one step, so a crash leaves the old file or the new one.
    ///
    /// - Parameter value: the value to write
    public func save(_ value: Value) throws {
        let data = try JSONCoding.encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Deletes the file. A missing file is fine.
    public func delete() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
        }
    }

    private func setAside(because error: any Error) {
        let manager = FileManager.default
        try? manager.removeItem(at: corruptURL)
        let kept = (try? manager.moveItem(at: url, to: corruptURL)) != nil
        report(
            "\(url.lastPathComponent) could not be read and counts as empty"
                + (kept ? ", kept as \(corruptURL.lastPathComponent)" : "") + ": \(Self.reason(error))")
    }

    private static func reason(_ error: any Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context), DecodingError.keyNotFound(_, let context),
            DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            let underlying = (context.underlyingError as? NSError)?.userInfo[NSDebugDescriptionErrorKey] as? String
            return [path.isEmpty ? nil : path, underlying ?? context.debugDescription]
                .compactMap { $0 }.joined(separator: ": ")
        default:
            return error.localizedDescription
        }
    }
}
