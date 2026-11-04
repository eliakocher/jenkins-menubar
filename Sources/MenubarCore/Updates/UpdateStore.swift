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
/// The app calls ``check()`` when it starts, when the Mac wakes, and when the panel or the window opens;
/// ``startWatching()`` adds a check shortly after a hashed file of the checkout changes, like after a `git pull`, and
/// every ten minutes in case FSEvents misses one. Hashing reads every source file, so it runs off the main actor. The
/// rebuild runs `build.sh --install` through ``Rebuilder`` and checks that the installed bundle is the new build; the
/// app then opens the bundle ``rebuild()`` returns and quits, and the next start tells whether the update took
/// (``launched(bundle:info:)``).
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
    /// a check was asked for while one ran: it runs again once that one ends, so a change during a hash isn't lost
    @ObservationIgnored private var checkAgain = false
    /// the checkout's hash when the last rebuild failed; the error stays until the checkout changes again
    @ObservationIgnored private var failedHash: String?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let hasher: @Sendable (BuildStamp) async -> String?
    @ObservationIgnored private let settle: Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    /// the running app's build, from ``launched(bundle:info:)``
    @ObservationIgnored private var runningBuild: BundleBuild?
    @ObservationIgnored private var watcher: CheckoutWatcher?
    @ObservationIgnored private var settling: Task<Void, Never>?
    @ObservationIgnored private var periodic: Task<Void, Never>?

    /// how often the checkout is hashed besides the watcher's changes, in case FSEvents misses one
    public static let recheckInterval: Duration = .seconds(10 * 60)

    /// Creates the store.
    ///
    /// - Parameters:
    ///   - stamp: what `build.sh` stamped into the app, `BuildStamp(infoDictionary: Bundle.main.infoDictionary)`; nil
    ///     for a build without it, which never offers an update
    ///   - runner: runs `build.sh`; the tests pass a fake
    ///   - log: the Activity log, which gets the rebuild's start, its end and "Update failed: <reason>"
    ///   - home: the home folder `build.sh --install` installs into
    ///   - defaults: where the rebuild leaves the ``UpdateHandover`` for the next start; nil keeps none
    ///   - settle: how long ``checkoutDidChange()`` waits for the checkout to settle, as a pull writes many files
    ///   - now: the clock of the handover
    public convenience init(
        stamp: BuildStamp?,
        runner: any ProcessRunner = SystemProcessRunner(),
        log: ActivityLog? = nil,
        home: URL = URL.homeDirectory,
        defaults: UserDefaults? = nil,
        settle: Duration = .seconds(2),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            stamp: stamp, runner: runner, log: log, home: home, defaults: defaults, settle: settle, now: now,
            hasher: { stamp in await Task.detached(priority: .utility) { stamp.currentSourceHash() }.value })
    }

    /// Creates the store with the hash computed by `hasher`; the tests pass one that answers when they say so.
    init(
        stamp: BuildStamp?, runner: any ProcessRunner, log: ActivityLog?, home: URL, defaults: UserDefaults?,
        settle: Duration, now: @escaping @Sendable () -> Date, hasher: @escaping @Sendable (BuildStamp) async -> String?
    ) {
        self.stamp = stamp
        self.rebuilder = stamp.map { Rebuilder(checkout: $0.sourceRoot, runner: runner, home: home) }
        self.log = log
        self.defaults = defaults
        self.settle = settle
        self.now = now
        self.hasher = hasher
    }

    /// Compares the checkout's sources with the app's stamp, off the main actor, and updates ``state``. A check while a
    /// rebuild runs or the new app is installed does nothing; a check asked for while one runs runs again after it.
    public func check() async {
        guard stamp != nil, !isBusy else { return }
        guard !checking else {
            checkAgain = true
            return
        }
        checking = true
        defer { checking = false }
        repeat {
            checkAgain = false
            await checkOnce()
        } while checkAgain && !isBusy
    }

    /// Checks again once the checkout has had ``settle`` without a further change: a `git pull` writes many files, and
    /// the watcher reports them over a few seconds.
    public func checkoutDidChange() {
        settling?.cancel()
        let settle = settle
        settling = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            await self?.check()
        }
    }

    /// Starts watching the checkout's hashed files, and a check every ``recheckInterval``. Without a stamp, or
    /// when it watches already, it does nothing.
    public func startWatching() {
        guard let stamp, watcher == nil else { return }
        let watcher = CheckoutWatcher(root: stamp.sourceRoot) { [weak self] in
            Task { @MainActor in self?.checkoutDidChange() }
        }
        self.watcher = watcher
        if !watcher.start() {
            Task { [log] in
                await log?.log(.warning, .app, "Couldn't watch the checkout for changes; the update check runs every ten minutes")
            }
        }
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.recheckInterval)
                guard !Task.isCancelled, let self else { return }
                await check()
            }
        }
    }

    /// Stops the watcher and the periodic check, as the app quits.
    public func stopWatching() {
        watcher?.stop()
        watcher = nil
        settling?.cancel()
        periodic?.cancel()
        periodic = nil
    }

    private func checkOnce() async {
        guard let stamp else { return }
        let current = await hasher(stamp)
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

        let checkoutHash = await hasher(stamp)
        var outcome = result
        if case .success(let app) = result {
            outcome = await verifyInstalled(app, running: stamp, checkoutHash: checkoutHash)
        }
        switch outcome {
        case .success(let app):
            state = .installed(app)
            return app
        case .failure(let error):
            failedHash = checkoutHash
            await log?.log(.error, .app, error.message, detail: error.output.isEmpty ? nil : error.output)
            state = .failed(reason: error.reason)
            return nil
        }
    }

    /// Checks that the bundle `build.sh` installed is the new build, before the app hands over to it; logs it, and
    /// leaves the ``UpdateHandover`` for the next start.
    private func verifyInstalled(_ app: URL, running: BuildStamp, checkoutHash: String?) async -> Result<URL, RebuildError> {
        let read = BundleBuild.read(bundle: app)
        let path = Self.displayPath(app)
        let missing = RebuildError(reason: "build.sh ended, but there is no complete app at \(path)")
        switch InstalledCheck.verify(installed: read, running: running, checkoutHash: checkoutHash) {
        case .missing:
            return .failure(missing)
        case .unchanged:
            return .failure(RebuildError(
                reason: "build.sh ended, but the app at \(path) is still this build (\(String(running.sourceHash.prefix(12))))"))
        case .current, .behindCheckout:
            break
        }
        guard let installed = read, let expected = installed.stamp?.sourceHash else {
            return .failure(missing)
        }
        await log?.log(.info, .app, "Installed the update: \(path), \(installed.versionLine), source hash \(installed.shortHash)")
        if let checkoutHash, checkoutHash != expected {
            await log?.log(.warning, .app, "The checkout changed during the rebuild: the new app offers the update again")
        }
        if let defaults {
            UpdateHandover(
                installedApp: path, expectedHash: expected, previousHash: running.sourceHash,
                previousVersion: runningBuild?.versionLine ?? "the previous version", installedAt: now()
            ).save(to: defaults)
        }
        return .success(app)
    }

    /// Logs which build started from where, and, when an update was installed before, whether it took: the start
    /// after a relaunch that still runs the old build shows the failure, so "Update Ready — Rebuild" tries again.
    /// Call it once at launch, before the first ``check()``.
    ///
    /// - Parameters:
    ///   - bundle: the running app's bundle, `Bundle.main.bundleURL`
    ///   - info: its Info.plist, `Bundle.main.infoDictionary`
    public func launched(bundle: URL, info: [String: Any]?) async {
        let build = BundleBuild(infoDictionary: info)
        runningBuild = build
        guard let stamp else { return }
        let path = Self.displayPath(bundle)
        await log?.log(
            .info, .app,
            "Started \(build.versionLine) from \(path), built from \(Self.displayPath(stamp.sourceRoot)) (source hash \(build.shortHash))")
        guard let defaults, let handover = UpdateHandover.take(from: defaults, now: now()) else { return }
        let installedPath = Self.displayPath(URL(filePath: handover.installedApp, directoryHint: .isDirectory))
        switch handover.outcome(running: stamp) {
        case .updated:
            await log?.log(.info, .app, "Updated from \(handover.previousVersion) to \(build.versionLine)")
        case .stillOld:
            let reason = path == installedPath
                ? "the app started again as the old build; rebuild once more"
                : "this copy at \(path) is the old build; the update is at \(installedPath): quit, and open that one"
            await log?.log(.warning, .app, "The update didn't take: \(reason)")
            failedHash = await hasher(stamp)
            state = .failed(reason: reason)
        case .other:
            break
        }
    }

    private var isBusy: Bool {
        switch state {
        case .rebuilding, .installed: true
        case .upToDate, .updateReady, .failed: false
        }
    }

    /// A folder's path without the final slash a directory URL has (``BundleBuild/plainPath(_:)``).
    private static func displayPath(_ url: URL) -> String {
        BundleBuild.plainPath(url)
    }
}
