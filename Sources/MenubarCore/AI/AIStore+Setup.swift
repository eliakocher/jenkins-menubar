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

    /// Returns the setup a chat run loads, listing the MCP tools first when that didn't happen this session. When the
    /// listing fails, the setup still loads, with every MCP tool off: the failure never turns a tool on.
    ///
    /// - Parameters:
    ///   - prompt: the prompt about to run
    ///   - followUp: whether it is a follow-up turn
    /// - Returns: the setup, or `nil` for safe mode
    func setupForChat(of prompt: ClaudePrompt, followUp: Bool = false) async -> ClaudeSetup? {
        guard usesSetup(for: prompt, followUp: followUp) else { return nil }
        if setupInventory.inventory == nil {
            await listSetup(force: false)
        }
        return ClaudeSetup(
            useClaudeMd: settings.useMyClaudeMd, inventory: setupInventory.inventory, serverChoices: settings.mcpServerChoices)
    }

    /// Lists the MCP tools of the user's setup once per app session; Settings' Refresh lists them again.
    ///
    /// - Parameter force: list again even when a listing is there
    public func listSetup(force: Bool) async {
        if let listing {
            await listing.value
            return
        }
        if !force, setupInventory.inventory != nil { return }
        setupInventory = .loading
        let engine = engine
        let task = Task { [weak self] in
            let state: SetupInventoryState
            do {
                state = .ready(try await engine.discoverSetup())
            } catch {
                state = .failed((error as? ClaudeFailure)?.message ?? error.localizedDescription)
            }
            guard let self else { return }
            self.setupInventory = state
            if case .ready(let inventory) = state {
                let split = inventory.split
                self.record(
                    "Claude setup listed: \(split.reading.count) reading MCP tools allowed, \(split.changing.count) kept off",
                    level: .info, source: .app)
            } else if case .failed = state {
                self.record("Claude setup couldn't be listed; every MCP tool stays off", level: .warning, source: .app)
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
