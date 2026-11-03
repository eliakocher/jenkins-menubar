import Foundation

/// Where the listing of the user's Claude Code setup stands (AI-09).
public enum SetupInventoryState: Equatable, Sendable {
    /// not asked for yet
    case unknown
    case loading
    case ready(ClaudeInventory)
    /// the listing failed, with the reason in a sentence
    case failed(String)

    /// the inventory, once there is one
    public var inventory: ClaudeInventory? {
        if case .ready(let inventory) = self { inventory } else { nil }
    }
}

extension AIStore {
    /// whether a prompt runs with the user's setup: the chats do, when the setting is on: a question about code, a
    /// question about a work item, and every follow-up. The explanations, summaries and digests stay in safe mode.
    func usesSetup(for prompt: ClaudePrompt, followUp: Bool) -> Bool {
        guard settings.isEnabled, settings.useMySetup else { return false }
        return followUp || prompt.useCase == .askAboutCode || prompt.useCase == .askAboutItem
    }

    /// how old the listing may get before a chat starts a quiet refresh of it
    static let listingStaleAfter: TimeInterval = 15 * 60

    /// Returns the setup a chat run loads, listing the MCP tools first when that didn't happen this session. When the
    /// listing fails, the setup still loads, with every MCP tool off: the failure never turns a tool on.
    ///
    /// The listing starts `claude` and every MCP server, which takes seconds, so a chat never waits for a fresh one. It
    /// reads the config's server names instead (a few small files) and denies every server the listing doesn't know: one
    /// added since stays off until the listing is made again. A listing that has grown old is refreshed in the
    /// background for the next chat.
    ///
    /// - Parameters:
    ///   - prompt: the prompt about to run
    ///   - followUp: whether it is a follow-up turn
    /// - Returns: the setup, or `nil` for safe mode
    func setupForChat(of prompt: ClaudePrompt, followUp: Bool = false) async -> ClaudeSetup? {
        guard usesSetup(for: prompt, followUp: followUp) else { return nil }
        if setupInventory.inventory == nil {
            await listSetup(force: false)
        } else if let listedAt = setupListedAt, now().timeIntervalSince(listedAt) > Self.listingStaleAfter, listing == nil {
            Task { [weak self] in await self?.listSetup(force: true, quietly: true) }
        }
        let configured = await configuredMcpServers?(prompt.readableFolder)
        return ClaudeSetup(
            useClaudeMd: settings.useMyClaudeMd, inventory: setupInventory.inventory, serverChoices: settings.mcpServerChoices,
            configuredServers: configured)
    }

    /// Lists the MCP tools of the user's setup once per app session; Settings' Refresh lists them again.
    ///
    /// - Parameters:
    ///   - force: list again even when a listing is there
    ///   - quietly: keep showing the current listing meanwhile, and keep it when this one fails
    public func listSetup(force: Bool, quietly: Bool = false) async {
        if let listing {
            await listing.value
            return
        }
        if !force, setupInventory.inventory != nil { return }
        if !quietly || setupInventory.inventory == nil {
            setupInventory = .loading
        }
        let engine = engine
        let task = Task { [weak self] in
            let state: SetupInventoryState
            do {
                state = .ready(try await engine.discoverSetup())
            } catch {
                state = .failed((error as? ClaudeFailure)?.message ?? error.localizedDescription)
            }
            guard let self else { return }
            if case .ready(let inventory) = state {
                self.setupInventory = state
                self.setupListedAt = self.now()
                let split = inventory.split
                self.record(
                    "Claude setup listed: \(split.reading.count) reading MCP tools allowed, \(split.changing.count) kept off",
                    level: .info, source: .app)
            } else if case .failed = state {
                // A quiet refresh that fails leaves the listing it had; the config check still covers new servers.
                let kept = quietly && self.setupInventory.inventory != nil
                if !kept {
                    self.setupInventory = state
                }
                self.record(
                    kept ? "Claude setup couldn't be refreshed; the earlier listing stays, new servers stay off"
                        : "Claude setup couldn't be listed; every MCP tool stays off",
                    level: .warning, source: .app)
            }
            self.listing = nil
        }
        listing = task
        await task.value
    }

    /// Reads the user's slash commands and skills, and the checkout's own, for the "/" list. A folder that was read last
    /// time isn't read again unless `force` is set.
    ///
    /// - Parameters:
    ///   - project: the checkout's folder, or `nil`
    ///   - force: read again
    public func loadSlashCommands(project: String?, force: Bool = false) async {
        if !force, slashCommandsProject == .some(project) { return }
        slashCommandsProject = .some(project)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = project.flatMap { $0.hasPrefix("/") ? URL(filePath: $0, directoryHint: .isDirectory) : nil }
        slashCommands = await Task.detached(priority: .utility) {
            SlashCommandCatalog.scan(home: home, project: folder)
        }.value
    }
}
