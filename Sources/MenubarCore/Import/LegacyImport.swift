import Foundation

/// The one-time import from jenkins-menubar at first start (IMP-01 to IMP-03, ACC-02).
///
/// It reads the old tool's tokens, `config/settings`, `config/team.conf` and its watched and hidden builds. The old
/// settings are applied to the preferences; the rest only fills in what MegaMonitor doesn't have yet, so a token,
/// team values, a watched job or a hidden build already there is kept. The old files and keychain items are left as
/// they are. A marker file, which holds the report, records the import, so later runs change nothing, even when the
/// old files changed. Run one import at a time.
public struct LegacyImport: Sendable {
    /// Where jenkins-menubar kept its files. Every path is injected, so the tests never see the real ones.
    public struct Locations: Hashable, Sendable {
        /// the checkout the app was built from (`MMSourceRoot`), often the old tool's folder too; looked at first
        public var storedCheckout: URL?
        /// SwiftBar's plugin folder, which holds `jenkins.30s.sh` or a link to it
        public var swiftBarPluginFolder: URL?
        /// `~/bin/jenkins-watch`, a link into the old folder
        public var watchLink: URL?
        /// `~/Library/Caches/jenkins-menubar`, with the `watched` and `hidden` files
        public var caches: URL

        public init(storedCheckout: URL?, swiftBarPluginFolder: URL?, watchLink: URL?, caches: URL) {
            self.storedCheckout = storedCheckout
            self.swiftBarPluginFolder = swiftBarPluginFolder
            self.watchLink = watchLink
            self.caches = caches
        }

        /// Returns the user's own locations.
        ///
        /// - Parameters:
        ///   - storedCheckout: the checkout the app was built from, ``BuildStamp/sourceRoot``
        ///   - home: the user's home folder
        ///   - swiftBarDefaults: SwiftBar's preferences, whose `PluginDirectory` is its plugin folder
        /// - Returns: the locations
        public static func standard(
            storedCheckout: URL?,
            home: URL = URL.homeDirectory,
            swiftBarDefaults: UserDefaults? = UserDefaults(suiteName: "com.ameba.SwiftBar")
        ) -> Locations {
            let pluginFolder = swiftBarDefaults?.string(forKey: "PluginDirectory").flatMap { path in
                path.isEmpty ? nil : URL(filePath: NSString(string: path).expandingTildeInPath, directoryHint: .isDirectory)
            }
            return Locations(
                storedCheckout: storedCheckout,
                swiftBarPluginFolder: pluginFolder,
                watchLink: home.appending(path: "bin/jenkins-watch", directoryHint: .notDirectory),
                caches: home.appending(path: "Library/Caches/jenkins-menubar", directoryHint: .isDirectory))
        }
    }

    /// the old plugin's name in SwiftBar's plugin folder, as the old `install.sh` linked it
    public static let pluginName = "jenkins.30s.sh"

    private let locations: Locations
    private let oldTokens: LegacyTokenFinder
    private let tokens: TokenStore
    private let preferences: PreferencesStore
    private let teamStore: TeamStore
    private let userState: UserStateStore
    private let log: ActivityLog?
    private let now: @Sendable () -> Date
    /// the marker, which holds the report
    public let markerURL: URL

    /// Creates the import. Nothing is read yet.
    ///
    /// - Parameters:
    ///   - locations: where the old tool kept its files
    ///   - oldTokens: where the old tool's tokens may be
    ///   - keychain: MegaMonitor's keychain, which the tokens go to
    ///   - preferences: the preferences the old settings go to
    ///   - teamStore: the projects the old team values go to
    ///   - userState: the state the watched and hidden builds go to
    ///   - applicationSupport: the folder of the marker, ``FileLocations/applicationSupport``
    ///   - log: the log the summary goes to
    ///   - now: the clock, for the report and the time the watched jobs were added
    public init(
        locations: Locations,
        oldTokens: LegacyTokenFinder,
        keychain: any Keychain,
        preferences: PreferencesStore,
        teamStore: TeamStore,
        userState: UserStateStore,
        applicationSupport: URL,
        log: ActivityLog?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locations = locations
        self.oldTokens = oldTokens
        self.tokens = TokenStore(keychain: keychain)
        self.preferences = preferences
        self.teamStore = teamStore
        self.userState = userState
        self.log = log
        self.now = now
        markerURL = applicationSupport.appending(path: "legacy-import.json", directoryHint: .notDirectory)
    }

    /// whether the import has run; a marker that can't be read counts too, so a damaged one never imports twice
    public var hasRun: Bool {
        FileManager.default.fileExists(atPath: markerURL.path(percentEncoded: false))
    }

    /// Imports, unless an import has run before.
    ///
    /// - Returns: what the import did; nil when it had run before, and nothing was changed
    public func runIfNeeded() async -> LegacyImportReport? {
        guard !hasRun else { return nil }
        let found = locateOldFolder()
        return await run(folder: found?.folder, foundBy: found?.source)
    }

    /// Imports from the folder the user chose in the welcome flow, whether an import ran before or not.
    ///
    /// - Parameter folder: the chosen folder; one without the old config files imports only the tokens and builds
    /// - Returns: what the import did
    @discardableResult
    public func run(chosenFolder folder: URL) async -> LegacyImportReport {
        await run(folder: Self.isOldFolder(folder) ? folder : nil, foundBy: .chosen)
    }

    /// Reads the report the marker holds.
    ///
    /// - Returns: the report of the last import; nil when none ran, or the marker can't be read
    public func recordedReport() -> LegacyImportReport? {
        (try? Data(contentsOf: markerURL)).flatMap { try? JSONCoding.decoder.decode(LegacyImportReport.self, from: $0) }
    }

    /// Finds the old tool's folder: the stored checkout, then the plugin in SwiftBar's plugin folder, then the
    /// `~/bin/jenkins-watch` link (Task 6.3). Both are followed to the file they link to; a plugin folder that is the
    /// old folder's own `plugins/` counts too.
    ///
    /// - Returns: the folder and how it was found; nil when none of them leads to one, and the welcome flow asks
    public func locateOldFolder() -> (folder: URL, source: OldFolderSource)? {
        if let checkout = locations.storedCheckout, Self.isOldFolder(checkout) {
            return (checkout, .storedCheckout)
        }
        // <old folder>/plugins/jenkins.30s.sh and <old folder>/bin/jenkins-watch: two levels up from the real file.
        let links: [(URL?, OldFolderSource)] = [
            (locations.swiftBarPluginFolder?.appending(path: Self.pluginName, directoryHint: .notDirectory), .swiftBarPlugin),
            (locations.watchLink, .watchLink),
        ]
        for case (let link?, let source) in links where Self.exists(link) {
            let folder = link.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            if Self.isOldFolder(folder) {
                return (folder.standardizedFileURL, source)
            }
        }
        return nil
    }

    /// Returns whether a folder is the old tool's: it has `config/settings` or `config/team.conf`, the files the old
    /// plugin creates at its first run.
    ///
    /// - Parameter folder: the folder
    /// - Returns: `true` for the old tool's folder
    public static func isOldFolder(_ folder: URL) -> Bool {
        ["config/settings", "config/team.conf"].contains { exists(folder.appending(path: $0, directoryHint: .notDirectory)) }
    }

    private func run(folder: URL?, foundBy: OldFolderSource?) async -> LegacyImportReport {
        var report = LegacyImportReport(date: now(), oldFolder: folder, foundBy: folder == nil ? nil : foundBy)
        for account in TokenAccount.allCases {
            report.tokens.append(TokenImport(account: account, outcome: await importToken(account)))
        }
        if let folder {
            importSettings(from: folder, into: &report)
            importTeam(from: folder, into: &report)
        }
        let cachesFound = Self.exists(locations.caches)
        if cachesFound {
            importBuilds(into: &report)
        }
        let oldKeychainUsed = report.tokens.contains { $0.outcome == .imported(.oldKeychain) }
        report.oldToolFound = folder != nil || cachesFound || oldKeychainUsed
        // The steps above noted what their files lacked; the rest is added around it, in the order of IMP-03.
        report.notMoved = neverMoved(in: report, oldKeychainUsed: oldKeychainUsed) + report.notMoved + tokensNotMoved(in: report)

        var failed = report.notMoved.contains { $0.isFailure }
        do {
            try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONCoding.encoder.encode(report).write(to: markerURL, options: .atomic)
        } catch {
            report.notMoved.append(.notSaved(what: "The import's record", reason: error.localizedDescription))
            failed = true
        }
        // The easter egg of an import that moved something, whose switch is at its default on this first launch (EGG-22).
        let summary = report.somethingMoved && !failed ? "\(report.summary). \(EggRules.importLine)" : report.summary
        await log?.log(failed ? .warning : .info, .app, summary, detail: report.detail)
        return report
    }

    private func importToken(_ account: TokenAccount) async -> TokenOutcome {
        if let stored = try? await tokens.token(account), !stored.isEmpty {
            return .kept
        }
        let found = await oldTokens.find(account)
        guard let value = found.value else {
            return .notFound(found.source)
        }
        do {
            try await tokens.store(value, for: account)
            return .imported(found.source)
        } catch {
            return .notStored(found.source, reason: error.localizedDescription)
        }
    }

    private func importSettings(from folder: URL, into report: inout LegacyImportReport) {
        guard let text = Self.read(folder.appending(path: "config/settings", directoryHint: .notDirectory)) else {
            report.notMoved.append(.settings)
            return
        }
        preferences.save(LegacyFormats.preferences(from: LegacyKeyValues(text: text), onto: preferences.load()))
        report.importedSettings = true
    }

    private func importTeam(from folder: URL, into report: inout LegacyImportReport) {
        let conf = Self.read(folder.appending(path: "config/team.conf", directoryHint: .notDirectory))
        let team = LegacyFormats.team(from: LegacyKeyValues(text: conf ?? ""))
        guard team != TeamValues() else {
            report.notMoved.append(.teamValues)
            return
        }
        var project = teamStore.primaryProject()
        // Team values someone already entered are kept.
        guard project.team == TeamValues() else { return }
        project.team = team
        do {
            try teamStore.save(project)
            report.importedTeam = true
        } catch {
            report.notMoved.append(.notSaved(what: "The team values", reason: error.localizedDescription))
        }
    }

    private func importBuilds(into report: inout LegacyImportReport) {
        let watched = LegacyFormats.watchedJobs(from: Self.read(locations.caches.appending(path: "watched")) ?? "")
        let hidden = LegacyFormats.hiddenBuilds(from: Self.read(locations.caches.appending(path: "hidden")) ?? "")
        guard !watched.isEmpty || !hidden.isEmpty else { return }
        let added = now()
        var watchedJobs = 0
        var hiddenBuilds = 0
        do {
            try userState.update(teamStore.primaryProject().id) { state in
                for job in watched where !state.watched.contains(where: { $0.job == job }) {
                    state.watched.append(WatchedJob(job: job, label: Build.label(forJob: job), added: added))
                    watchedJobs += 1
                }
                for (job, number) in hidden where state.hidden[job] == nil {
                    state.hidden[job] = number
                    hiddenBuilds += 1
                }
            }
            report.watchedJobs = watchedJobs
            report.hiddenBuilds = hiddenBuilds
        } catch {
            report.notMoved.append(.notSaved(what: "The watched and hidden builds", reason: error.localizedDescription))
        }
    }

    /// What never moves, once the old tool was there, and its folder, when only its traces were found.
    private func neverMoved(in report: LegacyImportReport, oldKeychainUsed: Bool) -> [NotMoved] {
        guard report.oldToolFound else { return [] }
        var items: [NotMoved] = [.notificationSettings]
        if oldKeychainUsed {
            items.append(.keychainAccess)
        }
        items += [.windowPositions, .labelMemoryAndCaches]
        if report.oldFolder == nil {
            items.append(.oldFolder)
        }
        return items
    }

    private func tokensNotMoved(in report: LegacyImportReport) -> [NotMoved] {
        report.tokens.compactMap { token in
            switch token.outcome {
            case .imported, .kept:
                nil
            case .notFound(.missing):
                // Without the old tool, a missing token is simply not set up yet, and the welcome flow asks for it.
                report.oldToolFound ? .token(token.account, token.outcome) : nil
            case .notFound, .notStored:
                .token(token.account, token.outcome)
            }
        }
    }

    /// Whether something is at the URL, a link that leads nowhere included.
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
    }

    private static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}
