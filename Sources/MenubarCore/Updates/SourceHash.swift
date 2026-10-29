import CryptoKit
import Foundation

/// The hash of everything the app is built from, which tells when the checkout has changed since the build (APP-05).
///
/// It equals the `MMSourceHash` that `build.sh` stamps into Info.plist: the SHA-256 of the `shasum -a 256` listing of
/// Package.swift, build.sh, Sources/ and icons/, without hidden files, sorted by path in byte order. `build.sh` is the
/// reference; a test runs its pipeline and compares.
public enum SourceHash {
    /// the files and folders hashed, relative to the checkout, as `build.sh` passes them to `find`
    public static let paths = ["Package.swift", "build.sh", "Sources", "icons"]

    /// Computes the hash of a checkout's sources.
    ///
    /// Like `find -type f`, only regular files count: symbolic links are neither followed nor hashed. A missing path
    /// adds nothing.
    ///
    /// - Parameter root: the checkout
    /// - Returns: 64 lowercase hex digits
    /// - Throws: the error of a folder or file that can't be read
    public static func compute(root: URL) throws -> String {
        var files: [String] = []
        for path in paths {
            try collectFiles(at: path, in: root, into: &files)
        }
        // `! -path '*/.*'`: a `*` in find's pattern matches `/` too, so a hidden name anywhere below a path counts.
        files.removeAll { $0.contains("/.") }
        files.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }

        var listing = Data()
        for file in files {
            let contents = try Data(contentsOf: root.appending(path: file, directoryHint: .notDirectory), options: .mappedIfSafe)
            listing.append(contentsOf: listingLine(digest: hex(SHA256.hash(data: contents)), path: file).utf8)
        }
        return hex(SHA256.hash(data: listing))
    }

    /// The line `shasum -a 256` prints for a file. A name with a backslash or a line break is escaped, and the line
    /// then starts with a backslash.
    static func listingLine(digest: String, path: String) -> String {
        guard path.contains("\\") || path.contains("\n") else {
            return "\(digest)  \(path)\n"
        }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
        return "\\\(digest)  \(escaped)\n"
    }

    private static func collectFiles(at path: String, in root: URL, into files: inout [String]) throws {
        let manager = FileManager.default
        let fullPath = root.appending(path: path).path(percentEncoded: false)
        // attributesOfItem doesn't follow a symbolic link, as find doesn't without -L.
        guard let type = (try? manager.attributesOfItem(atPath: fullPath))?[.type] as? FileAttributeType else {
            return
        }
        switch type {
        case .typeRegular:
            files.append(path)
        case .typeDirectory:
            for name in try manager.contentsOfDirectory(atPath: fullPath) {
                try collectFiles(at: path + "/" + name, in: root, into: &files)
            }
        default:
            break
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// What `build.sh` stamped into the app's Info.plist: the checkout the app was built from and the hash of its sources
/// then (APP-05).
public struct BuildStamp: Hashable, Sendable {
    /// the checkout, `MMSourceRoot`
    public var sourceRoot: URL
    /// the hash of its sources at build time, `MMSourceHash`
    public var sourceHash: String

    public init(sourceRoot: URL, sourceHash: String) {
        self.sourceRoot = sourceRoot
        self.sourceHash = sourceHash
    }

    /// Reads the stamp from an Info.plist, or returns `nil` when either value is missing, as in a build `swift run`
    /// made without `build.sh`.
    ///
    /// - Parameter infoDictionary: the app's Info.plist, like `Bundle.main.infoDictionary`
    public init?(infoDictionary: [String: Any]?) {
        guard let root = infoDictionary?[AppIdentity.sourceRootKey] as? String, !root.isEmpty,
              let hash = infoDictionary?[AppIdentity.sourceHashKey] as? String, !hash.isEmpty
        else { return nil }
        self.init(sourceRoot: URL(filePath: root, directoryHint: .isDirectory), sourceHash: hash)
    }

    /// Returns whether the checkout's sources differ from the ones the app was built from, so "Update ready —
    /// rebuild" applies. Computing the hash reads every source file: call it off the main actor.
    ///
    /// - Returns: `true` when they differ; `false` when they match, or when the checkout or its `build.sh` is gone or
    ///   can't be read, since there is nothing to rebuild from then
    public func checkoutChanged() -> Bool {
        currentSourceHash().map { $0 != sourceHash } ?? false
    }

    /// Computes the hash of the checkout's sources now. It reads every source file: call it off the main actor.
    ///
    /// - Returns: the hash; nil when the checkout or its `build.sh` is gone or can't be read, since there is nothing
    ///   to rebuild from then
    public func currentSourceHash() -> String? {
        let buildScript = sourceRoot.appending(path: "build.sh", directoryHint: .notDirectory)
        guard FileManager.default.isExecutableFile(atPath: buildScript.path(percentEncoded: false)) else {
            return nil
        }
        return try? SourceHash.compute(root: sourceRoot)
    }
}
