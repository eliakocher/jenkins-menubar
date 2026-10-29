import Foundation

/// Everything the app reaches outside itself: the network, the time, the keychain, the effects, the files, the
/// preferences and the system's conditions.
///
/// ``AppModel`` is built once from it. The app passes the real ones (``standard(effects:systemEvents:loginItem:defaults:)``);
/// the tests and the gallery pass fakes (`fake(root:…)`, debug builds only). Every side effect sits behind one of these,
/// so the stores and the scheduler can be tested without a network, a keychain or the user's files.
public struct Dependencies: @unchecked Sendable {
    // UserDefaults is documented as thread-safe, but the SDK doesn't mark it Sendable; every other value is Sendable.

    /// the transport of every Jenkins and GitLab request, before the `RequestRecorder` wraps it
    public var transport: any HTTPTransport
    /// the clock of the scheduler's waits and of the request times
    public var clock: any Clock<Duration>
    /// the time limits of the requests
    public var timeouts: Timeouts
    /// the current time, for the dates the checks keep and the hiding rules (HIDE-02)
    public var now: @Sendable () -> Date
    /// where the tokens are kept
    public var keychain: any Keychain
    /// the alert window, banners and sounds
    public var effects: any Effects
    /// the folders of the app's files
    public var fileLocations: FileLocations
    /// the UserDefaults suite of the preferences
    public var preferences: UserDefaults
    /// sleep and wake
    public var systemEvents: any SystemEvents
    /// whether the network can be reached
    public var reachability: any Reachability
    /// whether Low Power Mode is on
    public var powerMode: any PowerMode
    /// the app's login item
    public var loginItem: any LoginItem
    /// registers the global hotkey (APP-08)
    public var hotkeys: any HotkeyRegistrar
    /// what `build.sh` stamped into the app: the checkout and its sources' hash (APP-05); `nil` never offers an update
    public var buildStamp: BuildStamp?
    /// runs `build.sh` for the rebuild (APP-05)
    public var processRunner: any ProcessRunner

    public init(
        transport: any HTTPTransport,
        clock: any Clock<Duration>,
        timeouts: Timeouts,
        now: @escaping @Sendable () -> Date,
        keychain: any Keychain,
        effects: any Effects,
        fileLocations: FileLocations,
        preferences: UserDefaults,
        systemEvents: any SystemEvents,
        reachability: any Reachability,
        powerMode: any PowerMode,
        loginItem: any LoginItem,
        hotkeys: any HotkeyRegistrar,
        buildStamp: BuildStamp? = nil,
        processRunner: any ProcessRunner = SystemProcessRunner()
    ) {
        self.transport = transport
        self.clock = clock
        self.timeouts = timeouts
        self.now = now
        self.keychain = keychain
        self.effects = effects
        self.fileLocations = fileLocations
        self.preferences = preferences
        self.systemEvents = systemEvents
        self.reachability = reachability
        self.powerMode = powerMode
        self.loginItem = loginItem
        self.hotkeys = hotkeys
        self.buildStamp = buildStamp
        self.processRunner = processRunner
    }

    /// Returns the real dependencies, with the parts that need AppKit or ServiceManagement passed in by the app.
    ///
    /// - Parameters:
    ///   - effects: the app's `NativeEffects`
    ///   - systemEvents: the app's NSWorkspace sleep and wake events
    ///   - loginItem: the app's `SMAppService.mainApp` login item
    ///   - hotkeys: the app's Carbon hotkey registration
    ///   - defaults: the preferences' suite; the app's own domain by default, a suite of its own for the smoke check
    ///   - environment: the process environment, which may move the files (`MENUBAR_MONITOR_DATA_DIR`)
    /// - Returns: the dependencies: a `URLSessionTransport`, the continuous clock, the `security` keychain, the files in
    ///   `~/Library`, `NWPathMonitor`, the system's Low Power Mode, and the main bundle's build stamp
    public static func standard(
        effects: any Effects,
        systemEvents: any SystemEvents,
        loginItem: any LoginItem,
        hotkeys: any HotkeyRegistrar,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Dependencies {
        let clock = ContinuousClock()
        return Dependencies(
            transport: URLSessionTransport(connectTimeout: Timeouts.standard.connect, clock: clock),
            clock: clock,
            timeouts: .standard,
            now: { Date() },
            keychain: SecurityCLIKeychain(),
            effects: effects,
            fileLocations: .standard(environment: environment),
            preferences: defaults,
            systemEvents: systemEvents,
            reachability: PathReachability(),
            powerMode: SystemPowerMode(),
            loginItem: loginItem,
            hotkeys: hotkeys,
            buildStamp: BuildStamp(infoDictionary: Bundle.main.infoDictionary))
    }
}

#if DEBUG
extension Dependencies {
    /// Returns fakes for the tests and the gallery: nothing reaches the network, the login keychain or the user's
    /// files. Debug builds only.
    ///
    /// - Parameters:
    ///   - root: the folder the files go in, like a test's temporary folder
    ///   - defaults: the preferences' suite, one of the test's own
    ///   - transport: the transport; a `StubTransport` that answers nothing by default
    ///   - clock: the clock; a `TestClock` by default
    ///   - now: the current time
    ///   - keychain: the keychain; an empty `InMemoryKeychain` by default
    ///   - effects: the effects; `FakeEffects` by default
    ///   - systemEvents: sleep and wake; `FakeSystemEvents` by default
    ///   - reachability: the network; reachable `FakeReachability` by default
    ///   - powerMode: Low Power Mode; off by default
    ///   - loginItem: the login item; `FakeLoginItem` by default
    ///   - hotkeys: the hotkey registration; `FakeHotkeyRegistrar` by default
    ///   - buildStamp: the build stamp; none by default, so no update is offered
    ///   - processRunner: runs `build.sh`; give a fake whenever a test passes a build stamp
    /// - Returns: the dependencies
    @MainActor
    public static func fake(
        root: URL,
        defaults: UserDefaults,
        transport: any HTTPTransport = StubTransport(),
        clock: any Clock<Duration> = TestClock(),
        timeouts: Timeouts = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        keychain: any Keychain = InMemoryKeychain(),
        effects: any Effects = FakeEffects(),
        systemEvents: any SystemEvents = FakeSystemEvents(),
        reachability: any Reachability = FakeReachability(),
        powerMode: any PowerMode = FakePowerMode(),
        loginItem: (any LoginItem)? = nil,
        hotkeys: (any HotkeyRegistrar)? = nil,
        buildStamp: BuildStamp? = nil,
        processRunner: any ProcessRunner = SystemProcessRunner()
    ) -> Dependencies {
        Dependencies(
            transport: transport,
            clock: clock,
            timeouts: timeouts,
            now: now,
            keychain: keychain,
            effects: effects,
            fileLocations: FileLocations(root: root),
            preferences: defaults,
            systemEvents: systemEvents,
            reachability: reachability,
            powerMode: powerMode,
            loginItem: loginItem ?? FakeLoginItem(),
            hotkeys: hotkeys ?? FakeHotkeyRegistrar(),
            buildStamp: buildStamp,
            processRunner: processRunner)
    }
}
#endif
