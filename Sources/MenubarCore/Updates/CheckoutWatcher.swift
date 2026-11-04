import CoreServices
import Foundation

/// Watches the checkout the app was built from, so "Update Ready — Rebuild" shows soon after a `git pull`, without a
/// relaunch (APP-05).
///
/// FSEvents reports each changed file; only the files the source hash reads count (``SourceHash/isHashed(relativePath:)``),
/// so a build in `.build/` or `build/`, `.git` itself, the tests and the README start nothing. When FSEvents dropped
/// events, everything counts. FSEvents collects the events of a second into one call; the update store waits for the
/// checkout to settle before it hashes.
public final class CheckoutWatcher: @unchecked Sendable {
    /// the checkout, with its symbolic links resolved, as FSEvents reports paths
    private let root: String
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "local.megamonitor.checkout-watcher", qos: .utility)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var stream: FSEventStreamRef?

    /// Creates the watcher; ``start()`` starts it.
    ///
    /// - Parameters:
    ///   - root: the checkout, ``BuildStamp/sourceRoot``
    ///   - onChange: called on a background queue when a hashed file may have changed
    public init(root: URL, onChange: @escaping @Sendable () -> Void) {
        self.root = Self.standardPath(root.resolvingSymlinksInPath().path(percentEncoded: false))
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// Starts watching. Calling it again changes nothing.
    ///
    /// - Returns: whether FSEvents watches now; false when it couldn't start, for example for a checkout that is gone
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else {
            return true
        }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        // A closure that captures nothing, so it passes as a C function; the watcher comes back through `info`.
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            CheckoutWatcher.receive(info: info, count: count, paths: paths, flags: flags)
        }
        guard let created = FSEventStreamCreate(
            nil, callback, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
        else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    /// Stops watching. The watcher can start again.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Returns whether an FSEvents event can change the source hash.
    ///
    /// - Parameters:
    ///   - path: the event's path, absolute
    ///   - flags: the event's flags
    ///   - root: the checkout's path, absolute, without a final slash
    static func isRelevant(path: String, flags: FSEventStreamEventFlags, root: String) -> Bool {
        let rescan = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        if flags & rescan != 0 {
            return true
        }
        let path = standardPath(path)
        guard path.hasPrefix(root + "/") else {
            return path == root
        }
        return SourceHash.isHashed(relativePath: String(path.dropFirst(root.count + 1)))
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        let relevant = zip(paths, flags).contains { Self.isRelevant(path: $0, flags: $1, root: root) }
        if relevant {
            onChange()
        }
    }

    private static func standardPath(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func receive(
        info: UnsafeMutableRawPointer?, count: Int, paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        guard let info else {
            return
        }
        let watcher = Unmanaged<CheckoutWatcher>.fromOpaque(info).takeUnretainedValue()
        // kFSEventStreamCreateFlagUseCFTypes: the paths are a CFArray of CFString.
        let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray) as? [String] ?? []
        let eventFlags = Array(UnsafeBufferPointer(start: flags, count: count))
        watcher.handle(paths: list, flags: eventFlags)
    }
}
