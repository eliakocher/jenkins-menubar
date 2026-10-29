import Foundation

/// What "Open in Claude Code" starts Claude Code with (AI-05): a work item, a merge request, a failed build or a
/// checkout. The work on code happens in Claude Code, in the checkout; the app only hands over the context as Claude
/// Code's first prompt.
public enum ClaudeCodeContext: Hashable, Sendable {
    case workItem(WorkItem)
    case mergeRequest(MergeRequest)
    /// a failed build, with its failed tests when they are loaded
    case build(Build, page: URL?, failedTests: [FailedTest])
    /// a checkout and what it works on
    case workspace(Checkout, task: WorkspaceTask)

    /// Returns the checkout the context belongs in: the checkout itself; for a merge request or a build, the one on its
    /// source branch (``WorkspaceLinks``); for a work item, the one whose branch starts with its number. `nil` asks the
    /// user which.
    ///
    /// - Parameters:
    ///   - checkouts: the checkouts, in the order of Settings
    ///   - readings: what git last said of each
    ///   - mergeRequests: the loaded merge requests
    /// - Returns: the checkout, or `nil`
    public func checkout(
        in checkouts: [Checkout], readings: [Checkout.ID: CheckoutReading], mergeRequests: [MergeRequest]
    ) -> Checkout? {
        let links = WorkspaceLinks(checkouts: checkouts, readings: readings, mergeRequests: mergeRequests)
        let entry: WorkspaceLinks.Entry?
        switch self {
        case .workspace(let checkout, _):
            return checkout
        case .mergeRequest(let mergeRequest):
            entry = links.checkout(for: mergeRequest)
        case .build(let build, _, _):
            entry = links.checkout(for: build)
        case .workItem(let item):
            let number = item.isEpic ? nil : item.iid.flatMap { Int($0) }
            entry = number.flatMap { number in links.entries.first { BranchTask.number(of: $0.branch) == number } }
        }
        return entry.flatMap { entry in checkouts.first { $0.id == entry.id } }
    }

    /// Returns Claude Code's first prompt: what the item is, with its link, and what to start with. It always starts
    /// with the app's own words, never with `-`, so Claude Code never reads it as an option.
    ///
    /// - Parameter checkout: the checkout Claude Code starts in
    /// - Returns: the prompt, not redacted yet
    public func prompt(in checkout: Checkout) -> String {
        var lines = ["Context from menubar-monitor, for this checkout (\(checkout.name), base branch origin/\(checkout.baseBranch)):"]
        switch self {
        case .workItem(let item):
            lines.append("- Work item: \(item.reference) \"\(item.title)\" (\(item.type.rawValue.lowercased()), \(item.state.rawValue))")
            lines.append("- Link: \(item.webURL.absoluteString)")
            if !item.labels.isEmpty {
                lines.append("- Labels: \(item.labels.map(\.title).joined(separator: ", "))")
            }
            lines.append("")
            lines.append(
                "Read the work item (with your GitLab tools if you have them), look at this checkout, and propose a plan. "
                    + "Don't change code until I agree.")
        case .mergeRequest(let mergeRequest):
            lines.append("- Merge request: \(mergeRequest.reference) \"\(mergeRequest.title)\" by \(mergeRequest.author.username)")
            lines.append("- Link: \(mergeRequest.webURL.absoluteString)")
            if let branch = mergeRequest.sourceBranch {
                lines.append("- Source branch: \(branch)")
            }
            if let pipeline = mergeRequest.pipelineStatus {
                lines.append("- Pipeline: \(pipeline.rawValue.lowercased())")
            }
            lines.append("")
            if mergeRequest.roles.contains(.reviewRequested) && !mergeRequest.roles.contains(.authored) {
                lines.append(
                    "I'm asked to review it. Review its changes against origin/\(checkout.baseBranch) and list what you'd "
                        + "comment on, most important first. Don't change code.")
            } else {
                lines.append(
                    "It's my merge request. Check what it still needs: the open review feedback, the pipeline and the "
                        + "description. Propose the next steps; don't commit or push.")
            }
        case .build(let build, let page, let failedTests):
            lines.append("- Failed build: \(build.label) #\(build.number)\(build.title.map { " \"\($0)\"" } ?? ""), \(build.result?.rawValue ?? "FAILURE")")
            if let page {
                lines.append("- Build: \(page.absoluteString)")
            }
            if let stages = build.failedStages, !stages.isEmpty {
                lines.append("- Failed stages: \(stages.joined(separator: ", "))")
            }
            for test in failedTests.prefix(10) {
                let name = test.className.isEmpty ? test.name : "\(test.className).\(test.name)"
                lines.append("- Failed test: \(name)\(test.message.map { ": " + ClaudePrompt.firstLine($0) } ?? "")")
            }
            if failedTests.count > 10 {
                lines.append("- and \(failedTests.count - 10) more failed tests")
            }
            lines.append("")
            lines.append(
                "Find the cause of this failure in this checkout (the build log is on the build's page) and propose a "
                    + "fix. Don't commit or push.")
        case .workspace(_, let task):
            if let number = task.number {
                lines.append("- Work item: #\(number)\(task.title.map { " \"\($0)\"" } ?? "")")
            }
            if let url = task.workItemURL {
                lines.append("- Work item link: \(url.absoluteString)")
            }
            if let mergeRequest = task.mergeRequest {
                lines.append("- Merge request: \(mergeRequest.reference) \(mergeRequest.webURL.absoluteString)")
            }
            if let build = task.build {
                lines.append("- Last Jenkins build: #\(build.number) \(build.result?.rawValue ?? "running")")
            }
            lines.append("")
            lines.append("Look at this checkout's branch and its changes, and tell me where the task stands and what's next.")
        }
        return lines.joined(separator: "\n")
    }
}

/// Starts Claude Code in a Terminal window, in a checkout, with a first prompt (AI-05), without ever putting the
/// prompt or a path into a shell command.
///
/// The app writes a folder of its own (mode 700) with four files: a fixed `.command` script, and the checkout's path,
/// `claude`'s path and the prompt as plain text (mode 600). `open -a Terminal` runs the script; the script reads the
/// three values with `$(<file)` into quoted variables, deletes the folder, changes to the checkout and runs
/// `claude "$prompt"`. The script's text never changes, so no item title, path or log line can ever be read as shell
/// syntax: zsh never evaluates a variable's value. The prompt is an argument of the interactive `claude`, which is how
/// Claude Code takes a first prompt; it is redacted like everything the app sends.
public enum ClaudeCodeLaunch {
    /// the script, the same for every launch
    public static let script = """
        #!/bin/zsh -f
        # Written by menubar-monitor's "Open in Claude Code". Starts Claude Code in a checkout with a first prompt.
        # The checkout, the program and the prompt are read from the files next to this script as plain text; nothing
        # in them runs as a command. The folder deletes itself before Claude Code starts.
        here=${0:A:h}
        dir=$(<"$here/directory")
        claude=$(<"$here/claude")
        prompt=$(<"$here/prompt")
        rm -rf -- "$here"
        cd -- "$dir" || exit 1
        clear
        exec "$claude" "$prompt"

        """

    /// the script's file name; Terminal runs `.command` files
    public static let scriptName = "open-in-claude-code.command"

    /// Writes the launch folder.
    ///
    /// - Parameters:
    ///   - prompt: the first prompt, redacted
    ///   - directory: the checkout's path
    ///   - claude: `claude`'s full path
    ///   - parent: the folder the launch folder goes in
    /// - Returns: the script to open with Terminal
    public static func write(prompt: String, directory: String, claude: URL, in parent: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = parent.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let values = [
            "directory": directory,
            "claude": claude.path(percentEncoded: false),
            "prompt": prompt,
        ]
        for (name, value) in values {
            let file = folder.appending(path: name, directoryHint: .notDirectory)
            guard manager.createFile(atPath: file.path(percentEncoded: false), contents: Data(value.utf8),
                                     attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let script = folder.appending(path: scriptName, directoryHint: .notDirectory)
        guard manager.createFile(atPath: script.path(percentEncoded: false), contents: Data(Self.script.utf8),
                                 attributes: [.posixPermissions: 0o700]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return script
    }

    /// Deletes the launch folders a script never got to delete, like one whose Terminal window never opened, once they
    /// are a day old.
    ///
    /// - Parameters:
    ///   - parent: the folder the launch folders are in
    ///   - now: the current time
    public static func removeLeftovers(in parent: URL, now: Date) {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
            if now.timeIntervalSince(created) > 86_400 {
                try? manager.removeItem(at: folder)
            }
        }
    }
}
