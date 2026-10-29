import Foundation
import Observation

/// Where the app's update stands (APP-05).
public enum UpdateState: Sendable, Hashable {
    /// the app was built from the checkout as it is now, or there is no checkout to rebuild from
    case upToDate
    /// the checkout changed since the build: "Update Ready — Rebuild" shows in the panel footer and the window toolbar
    case updateReady
    /// `build.sh --install` runs
    case rebuilding(RebuildProgress)
    /// the rebuild failed: the error row shows the reason, and "Update Ready — Rebuild" tries again
    case failed(reason: String)
    /// the new app is installed; the app opens it and quits
    case installed(URL)
}

/// Offers the rebuild when the checkout's sources no longer match the hash stamped into the app, and runs it when
/// clicked (APP-05).
///
/// The app calls ``check()`` when it starts, when the Mac wakes, and when the panel or the window opens. Hashing reads
/// every source file, so it runs off the main actor. The rebuild runs `build.sh --install` through ``Rebuilder``; the
/// app then opens the bundle ``rebuild()`` returns and quits.
@Observable
@MainActor
public final class UpdateStore {
    /// where the update stands
    public private(set) var state: UpdateState = .upToDate

    /// whether "Update Ready — Rebuild" shows, and the status icon has its marker: also after a failed rebuild, to try
    /// again
    public var offersRebuild: Bool {
        switch state {
        case .updateReady, .failed: true
        case .upToDate, .rebuilding, .installed: false
        }
    }

    @ObservationIgnored private let stamp: BuildStamp?
    @ObservationIgnored private let rebuilder: Rebuilder?
    @ObservationIgnored private let log: ActivityLog?
    @ObservationIgnored private var checking = false
    /// the checkout's hash when the last rebuild failed; the error stays until the checkout changes again
    @ObservationIgnored private var failedHash: String?

    /// Creates the store.
    ///
    /// - Parameters:
    ///   - stamp: what `build.sh` stamped into the app, `BuildStamp(infoDictionary: Bundle.main.infoDictionary)`; nil
    ///     for a build without it, which never offers an update
    ///   - runner: runs `build.sh`; the tests pass a fake
    ///   - log: the Activity log, which gets the rebuild's start, its end and "Update failed: <reason>"
    ///   - home: the home folder `build.sh --install` installs into
    public init(
        stamp: BuildStamp?,
        runner: any ProcessRunner = SystemProcessRunner(),
        log: ActivityLog? = nil,
        home: URL = URL.homeDirectory
    ) {
        self.stamp = stamp
        self.rebuilder = stamp.map { Rebuilder(checkout: $0.sourceRoot, runner: runner, home: home) }
        self.log = log
    }

    /// Compares the checkout's sources with the app's stamp, off the main actor, and updates ``state``. A check while
    /// one runs, a rebuild runs, or the new app is installed does nothing.
    public func check() async {
        guard let stamp, !checking, !isBusy else { return }
        checking = true
        defer { checking = false }
        let current = await Self.currentHash(of: stamp)
        guard !isBusy else { return }

        guard let current, current != stamp.sourceHash else {
            failedHash = nil
            state = .upToDate
            return
        }
        if case .failed = state, current == failedHash {
            return
        }
        if state != .updateReady {
            await log?.log(.info, .app, "Update ready: the checkout changed since this build")
        }
        failedHash = nil
        state = .updateReady
    }

    /// Runs `build.sh --install` while ``state`` shows its progress. Only works while ``offersRebuild``.
    ///
    /// Logs info when it starts and ends; a failure logs error "Update failed: <reason>" and shows the error row.
    ///
    /// - Returns: the installed app, which the app opens before it quits; nil when the rebuild failed or wasn't
    ///   offered
    @discardableResult
    public func rebuild() async -> URL? {
        guard let stamp, let rebuilder, offersRebuild else { return nil }
        state = .rebuilding(.starting)
        await log?.log(.info, .app, "Rebuilding the app from \(Self.displayPath(rebuilder.checkout))")

        // A stream keeps the steps in order, and none arrives after the rebuild has ended.
        let (steps, continuation) = AsyncStream.makeStream(of: RebuildProgress.self, bufferingPolicy: .bufferingNewest(1))
        let display = Task { @MainActor [weak self] in
            for await step in steps {
                if case .rebuilding = self?.state {
                    self?.state = .rebuilding(step)
                }
            }
        }
        let result: Result<URL, RebuildError>
        do {
            result = .success(try await rebuilder.rebuild { continuation.yield($0) })
        } catch let error as RebuildError {
            result = .failure(error)
        } catch {
            result = .failure(RebuildError(reason: error.localizedDescription))
        }
        continuation.finish()
        await display.value

        switch result {
        case .success(let app):
            await log?.log(.info, .app, "Installed the update: \(Self.displayPath(app))")
            state = .installed(app)
            return app
        case .failure(let error):
            failedHash = await Self.currentHash(of: stamp)
            await log?.log(.error, .app, error.message, detail: error.output.isEmpty ? nil : error.output)
            state = .failed(reason: error.reason)
            return nil
        }
    }

    private var isBusy: Bool {
        switch state {
        case .rebuilding, .installed: true
        case .upToDate, .updateReady, .failed: false
        }
    }

    /// A folder's path without the final slash a directory URL has.
    private static func displayPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func currentHash(of stamp: BuildStamp) async -> String? {
        await Task.detached(priority: .utility) { stamp.currentSourceHash() }.value
    }
}
