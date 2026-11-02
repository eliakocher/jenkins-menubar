import CryptoKit
import Foundation

/// The kind of a detail kept in the ``DetailCache``, like a description or a merge request's discussions; its name
/// keeps the kinds apart on disk.
public struct DetailKind<Value: Codable & Sendable>: Hashable, Sendable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }
}

/// A detail as the cache keeps it: the value, the item's `updatedAt` it belongs to, and when it was saved.
public struct DetailEntry<Value: Codable & Sendable>: Codable, Sendable {
    public var value: Value
    /// the item's `updatedAt` the value belongs to; `nil` for what never changes, like a finished build's
    public var updatedAt: Date?
    public var savedAt: Date

    public init(value: Value, updatedAt: Date?, savedAt: Date) {
        self.value = value
        self.updatedAt = updatedAt
        self.savedAt = savedAt
    }
}

/// The details the user opened (descriptions, discussions, merge request details, linked items, finished builds), kept
/// on disk so an item opened again after a relaunch shows at once; its store reloads it quietly then (OD-07, Task
/// 7.06).
///
/// One JSON file per detail, named by a hash of its kind and key, in `~/Library/Caches/MegaMonitor/details`. Only the
/// newest details that fit in ``maxBytes`` stay, ``maxFiles`` at most: a save drops the least recently used beyond
/// that, and a load counts as a use. A file that can't be read or written only costs the instant display.
public final class DetailCache: @unchecked Sendable {
    /// 30 MB
    public static let defaultMaxBytes = 31_457_280
    public static let defaultMaxFiles = 600

    public let folder: URL
    public let maxBytes: Int
    public let maxFiles: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// the kept files by name with their size and last use, read from the folder at the first save
    private var index: [String: (bytes: Int, used: Date)]?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .exactSeconds
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .exactSeconds
        return decoder
    }()

    public init(
        folder: URL, maxBytes: Int = defaultMaxBytes, maxFiles: Int = defaultMaxFiles, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.folder = folder
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles
        self.now = now
    }

    /// Returns a kept detail and counts it as used; `nil` when none is kept or it can't be read.
    ///
    /// - Parameters:
    ///   - kind: the kind of detail
    ///   - key: the item, like its full reference
    public func load<Value>(_ kind: DetailKind<Value>, key: String) -> DetailEntry<Value>? {
        let name = Self.fileName(kind: kind.name, key: key)
        return lock.withLock {
            guard let data = try? Data(contentsOf: url(of: name)),
                let entry = try? decoder.decode(DetailEntry<Value>.self, from: data)
            else {
                return nil
            }
            touch(name, bytes: data.count)
            return entry
        }
    }

    /// Keeps a detail, replacing the one kept before, then drops the least recently used beyond the limits.
    ///
    /// - Parameters:
    ///   - value: the detail
    ///   - updatedAt: the item's `updatedAt` it belongs to; `nil` for what never changes
    ///   - kind: the kind of detail
    ///   - key: the item, like its full reference
    public func save<Value>(_ value: Value, updatedAt: Date?, as kind: DetailKind<Value>, key: String) {
        let name = Self.fileName(kind: kind.name, key: key)
        lock.withLock {
            guard let data = try? encoder.encode(DetailEntry(value: value, updatedAt: updatedAt, savedAt: now())) else {
                return
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url(of: name), options: .atomic)
            } catch {
                return
            }
            touch(name, bytes: data.count)
            evict()
        }
    }

    /// Deletes every kept detail, as when the GitLab token is removed.
    public func clear() {
        lock.withLock {
            try? FileManager.default.removeItem(at: folder)
            index = [:]
        }
    }

    /// The bytes the kept details take together.
    public func totalBytes() -> Int {
        lock.withLock { currentIndex().values.reduce(0) { $0 + $1.bytes } }
    }

    // MARK: - Private, under the lock

    private func touch(_ name: String, bytes: Int) {
        var index = currentIndex()
        let time = now()
        index[name] = (bytes, time)
        self.index = index
        // The file's date carries the use over a relaunch.
        try? FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: url(of: name).path)
    }

    private func evict() {
        var index = currentIndex()
        var total = index.values.reduce(0) { $0 + $1.bytes }
        let oldestFirst = index.sorted { $0.value.used < $1.value.used }.map(\.key)
        for name in oldestFirst where index.count > maxFiles || total > maxBytes {
            total -= index[name]?.bytes ?? 0
            index[name] = nil
            try? FileManager.default.removeItem(at: url(of: name))
        }
        self.index = index
    }

    private func currentIndex() -> [String: (bytes: Int, used: Date)] {
        if let index {
            return index
        }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        var read: [String: (bytes: Int, used: Date)] = [:]
        for url in urls where url.pathExtension == "json" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            read[url.deletingPathExtension().lastPathComponent] = (values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
        index = read
        return read
    }

    private func url(of name: String) -> URL {
        folder.appending(path: "\(name).json", directoryHint: .notDirectory)
    }

    /// The kind's name and the first 32 hex digits of the key's SHA-256: no reference or path ends up in a file name.
    static func fileName(kind: String, key: String) -> String {
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(kind)-\(hash)"
    }
}

extension JSONEncoder.DateEncodingStrategy {
    /// Seconds since the reference date as a double, so a saved `updatedAt` compares equal after a round trip.
    fileprivate static var exactSeconds: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    /// The counterpart of `JSONEncoder.DateEncodingStrategy.exactSeconds`.
    fileprivate static var exactSeconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            Date(timeIntervalSinceReferenceDate: try decoder.singleValueContainer().decode(Double.self))
        }
    }
}
