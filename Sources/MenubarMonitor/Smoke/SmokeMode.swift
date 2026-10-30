import Foundation
import MenubarCore

/// `MegaMonitor --smoke --stub <URL>`: the launch steps, one Jenkins check and one GitLab load against a stub
/// server, then exit (Task 4.7). `scripts/smoke.sh` runs it from the built bundle.
///
/// It never touches the user's data or screen:
/// - every file goes into `MENUBAR_MONITOR_DATA_DIR`, which must be set;
/// - the preferences go into a UserDefaults suite of their own, emptied before and after;
/// - the tokens are made up and kept in memory, never in the login keychain;
/// - the import looks only inside the data folder, with no old keychain, environment or `~/.zshrc`;
/// - no NSApplication runs: no status item, window, banner, sound or login item.
///
/// It prints the Activity entries and exits with 0 when the check found no problem, 1 when it did, and 2 when it
/// couldn't run.
enum SmokeMode {
    /// the preferences' suite, which is never the app's own domain
    static let defaultsSuite = "\(AppIdentity.bundleID).smoke"
    /// the made-up Jenkins user, whose jobs in the fixtures count as mine
    static let jenkinsUser = "jdoe"

    @MainActor
    static func run(arguments: [String]) -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard let stub = value(of: "--stub", in: arguments).flatMap(URL.init(string:)), stub.host() != nil else {
            fail("usage: MENUBAR_MONITOR_DATA_DIR=<folder> MegaMonitor --smoke --stub <URL>")
        }
        guard let folder = environment[FileLocations.dataDirectoryVariable], !folder.isEmpty else {
            fail("the smoke check needs \(FileLocations.dataDirectoryVariable), so it never touches the user's files")
        }
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            fail("can't open the UserDefaults suite \(defaultsSuite)")
        }
        defaults.removePersistentDomain(forName: defaultsSuite)
        Task { @MainActor in
            let status = await check(stub: stub, folder: URL(filePath: folder, directoryHint: .isDirectory), defaults: defaults)
            defaults.removePersistentDomain(forName: defaultsSuite)
            exit(status)
        }
        // Runs the main queue, and with it the main actor, until the task exits.
        dispatchMain()
    }

    @MainActor
    private static func check(stub: URL, folder: URL, defaults: UserDefaults) async -> Int32 {
        let effects = SmokeEffects()
        var dependencies = Dependencies.standard(
            effects: effects, systemEvents: NoSystemEvents(), loginItem: InertLoginItem(), hotkeys: InertHotkeys(),
            defaults: defaults)
        dependencies.keychain = MemoryKeychain()
        do {
            try await seed(dependencies, stub: stub)
        } catch {
            print("smoke: can't set up the data folder: \(error.localizedDescription)")
            return 2
        }

        let model = AppModel(dependencies: dependencies)
        let shell = AppShell(model: model, legacySources: .none(in: folder), defaultBrowser: InertDefaultBrowser())
        await shell.importIfNeeded()

        let outcome: CheckOutcome
        do {
            outcome = try await model.pipelines.check(reason: .start)
        } catch {
            print("smoke: the check was cancelled")
            return 2
        }
        // The GitLab load the panel or the window starts when it shows the merge requests and work items (OD-01).
        await model.mergeRequests.load()
        await model.workItems.load()
        await model.settled()

        for entry in await model.log.entries() {
            print("smoke: \(entry.level.rawValue) \(entry.source.rawValue) \(entry.message)\(entry.outcome.map { " [\($0)]" } ?? "")")
        }
        for call in await effects.calls {
            print("smoke: effect \(call)")
        }
        let pipelines = model.pipelines
        let problems = [pipelines.problem, model.mergeRequests.problem, model.workItems.problem].compactMap { $0 }
        print("smoke: check \(outcome.rawValue), my builds \(pipelines.myBuilds.count), problems: \(problems.isEmpty ? "none" : problems.map(\.message).joined(separator: "; "))")
        return outcome == .success && problems.isEmpty ? 0 : 1
    }

    /// Writes the made-up tokens and the team values that point at the stub server, as Settings would.
    private static func seed(_ dependencies: Dependencies, stub: URL) async throws {
        let tokens = TokenStore(keychain: dependencies.keychain)
        try await tokens.store(TokenStore.jenkinsToken(user: jenkinsUser, apiToken: "smoke-api-token"), for: .jenkins)
        try await tokens.store("smoke-gitlab-token", for: .gitlab)
        let base = stub.absoluteString.hasSuffix("/") ? String(stub.absoluteString.dropLast()) : stub.absoluteString
        let team = TeamStore(folder: dependencies.fileLocations.applicationSupport) { print("smoke: \($0)") }
        try team.save(Project(id: .main, team: TeamValues(
            jenkinsJobURL: "\(base)/job/project", gitLabURL: base, gitLabProject: "group/project",
            committedLabel: "committed", slotLabelPrefix: "slot::", ignoredMergeRequestPrefix: "[cascade]")))
    }

    private static func value(of option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(2)
    }
}
