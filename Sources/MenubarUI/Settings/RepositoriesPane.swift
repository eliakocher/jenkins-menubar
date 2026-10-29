import MenubarCore
import SwiftUI
import UniformTypeIdentifiers

/// What Settings → Repositories knows of the Open in IDE program.
enum ProgramLookup: Hashable, Sendable {
    /// the command is empty
    case off
    /// a quote isn't closed
    case unclosedQuote
    /// the lookup runs
    case looking
    /// found at this path
    case found(String)
    /// not found under the name typed
    case notFound(String)
}

/// Settings → Repositories' form (WS-01, WS-05): the folders and patterns with their base branches and what each found,
/// the Open in IDE command with how it will run, and the checkouts found. It draws only what it is given.
struct RepositoriesSettingsForm: View {
    @Binding var settings: RepositorySettings
    let findings: [FolderFindings]
    let readings: [Checkout.ID: CheckoutReading]
    let home: URL
    let program: ProgramLookup
    var onAddFolder: () -> Void = {}
    var onSubmit: () -> Void = {}

    var body: some View {
        Form {
            foldersSection
            ideSection
            checkoutsSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Folders

    private var foldersSection: some View {
        Section {
            if settings.folders.isEmpty {
                Text("No folders yet")
                    .foregroundStyle(.secondary)
            }
            ForEach($settings.folders) { $folder in
                folderRow($folder)
            }
            HStack {
                Button("Add Folder…", action: onAddFolder)
                Button("Add Pattern") {
                    settings.folders.append(RepositoryFolder(path: "~/"))
                }
                Spacer()
            }
        } header: {
            Text("Folders")
        } footer: {
            SettingsFooter(
                "A checkout's folder, or a pattern whose * stands for one folder level: ~/workspaces/*/project finds "
                    + "the project in every folder of ~/workspaces. A checkout is a folder with .git in it. The base "
                    + "branch is what tasks start from; the app compares with origin/<base> and never fetches.")
        }
    }

    private func folderRow(_ folder: Binding<RepositoryFolder>) -> some View {
        let id = folder.wrappedValue.id
        let found = findings.first { $0.folder == id }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: folder.wrappedValue.path.contains("*") ? "folder.badge.gearshape" : "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                TextField("Folder", text: folder.path, prompt: Text(verbatim: "~/workspaces/*/project"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .onSubmit(onSubmit)
                    .help(folder.wrappedValue.path)
                TextField("Base branch", text: folder.baseBranch, prompt: Text(verbatim: RepositoryFolder.defaultBaseBranch))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .frame(width: 96)
                    .onSubmit(onSubmit)
                    .help("The base branch, compared as origin/\(folder.wrappedValue.effectiveBaseBranch)")
                Button {
                    settings.folders.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove")
                .accessibilityLabel("Remove")
            }
            if let found {
                findingsLine(found)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func findingsLine(_ found: FolderFindings) -> some View {
        if let problem = found.problem {
            StatusLine(.problem, problem.message)
        } else {
            let names = found.checkouts.map(\.name)
            let count = "\(names.count) checkout\(names.count == 1 ? "" : "s")"
            StatusLine(.ok, names.count > 1 ? "\(count): \(names.joined(separator: ", "))" : count)
        }
    }

    // MARK: - Open in IDE

    private var ideSection: some View {
        Section {
            LabeledContent("Command") {
                TextField("Command", text: $settings.ideCommand, prompt: Text(verbatim: "code {path}"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .multilineTextAlignment(.trailing)
                    .onSubmit(onSubmit)
            }
            programLine
            if let preview {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "For \(preview.name), it runs:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    PillFlowLayout(spacing: 4, lineSpacing: 4) {
                        ForEach(Array(preview.words.enumerated()), id: \.offset) { index, word in
                            ArgumentPill(text: word, isProgram: index == 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } header: {
            Text("Open in IDE")
        } footer: {
            SettingsFooter(
                "Runs without a shell: the program, then each word as one argument, like code {path}, idea {path} or "
                    + "your team's tool with open {name}. {path} is the checkout's folder, {name} its name; quotes keep "
                    + "spaces in a word. Kept in your own settings, never in the team file.")
        }
    }

    @ViewBuilder
    private var programLine: some View {
        switch program {
        case .off:
            StatusLine(.note, "Off: Open in IDE stays disabled")
        case .unclosedQuote:
            StatusLine(.problem, "A quote isn't closed")
        case .looking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Looking for the program…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .found(let path):
            StatusLine(.ok, "Found \(WorkspaceDiscovery.abbreviate(path, home: home))")
        case .notFound(let name):
            StatusLine(.problem, "Couldn't find \(name): enter its full path, like /usr/local/bin/\(name)")
        }
    }

    /// The words the command runs with for the first checkout, so the user sees one pill per argument.
    private var preview: (name: String, words: [String])? {
        guard let checkout = findings.flatMap(\.checkouts).first,
              let command = LaunchCommand.make(settings.ideCommand, name: checkout.name, path: checkout.path) else {
            return nil
        }
        return (checkout.name, [command.program] + command.arguments)
    }

    // MARK: - Checkouts

    private var checkoutsSection: some View {
        Section {
            let checkouts = findings.flatMap(\.checkouts)
            if checkouts.isEmpty {
                Text("None found yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(checkouts) { checkout in
                LabeledContent {
                    Text(verbatim: readings[checkout.id]?.state?.status.branch ?? "")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    HStack(spacing: 8) {
                        WorkspaceTile(kind: kind(of: checkout), size: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: checkout.name)
                            Text(verbatim: WorkspaceDiscovery.abbreviate(checkout.path, home: home))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        } header: {
            Text("Checkouts Found")
        } footer: {
            SettingsFooter("The main window's Workspaces section (⌘5) shows them with their tasks.")
        }
    }

    private func kind(of checkout: Checkout) -> WorkspaceRowModel.Kind {
        switch readings[checkout.id] {
        case .read(let state)?:
            if state.isFree(baseBranch: checkout.baseBranch) {
                .free
            } else if !state.isClean {
                .changed
            } else {
                state.status.branch == nil ? .detached : .working
            }
        case .failed?: .problem
        case nil: .unknown
        }
    }
}

/// One argument of the command, as a small monospaced pill: the program in the accent color, each argument apart, so
/// a path with spaces visibly stays one argument.
private struct ArgumentPill: View {
    let text: String
    let isProgram: Bool

    var body: some View {
        Text(verbatim: text.isEmpty ? "\"\"" : text)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(isProgram ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .background(
                isProgram ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .help(text)
    }
}

/// Settings → Repositories, from the workspaces store. Edits are saved once typing pauses, on Return, and when the pane
/// goes; while it shows, the store finds and reads the checkouts.
struct RepositoriesPane: View {
    @Environment(AppModel.self) private var model
    @ViewState private var draft: RepositorySettings?
    @ViewState private var isPickingFolder = false
    @ViewState private var program: ProgramLookup = .off

    /// the name the pane shows the checkouts under
    static let host = "repositories-settings"

    var body: some View {
        let store = model.workspaces
        RepositoriesSettingsForm(
            settings: Binding(get: { draft ?? store.settings }, set: { draft = $0 }),
            findings: store.findings, readings: store.readings, home: store.homeFolder, program: program,
            onAddFolder: { isPickingFolder = true },
            onSubmit: save)
            .task(id: draft) {
                // The same pause as the team values (TEAM-01).
                try? await Task.sleep(for: SettingsStore.teamSaveDelay)
                if !Task.isCancelled {
                    save()
                }
            }
            .task(id: draft?.ideCommand ?? store.settings.ideCommand) {
                await lookUpProgram(draft?.ideCommand ?? store.settings.ideCommand)
            }
            .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result else {
                    return
                }
                Task {
                    let path = await store.suggestedPath(for: url)
                    var settings = draft ?? store.settings
                    settings.folders.append(RepositoryFolder(path: path))
                    draft = settings
                    save()
                }
            }
            .onAppear {
                store.show(by: Self.host)
            }
            .onDisappear {
                save()
                store.hide(by: Self.host)
            }
    }

    private func save() {
        if let draft {
            model.workspaces.update(draft)
        }
    }

    private func lookUpProgram(_ command: String) async {
        guard let words = LaunchCommand.words(of: command) else {
            program = .unclosedQuote
            return
        }
        guard let name = words.first else {
            program = .off
            return
        }
        program = .looking
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else {
            return
        }
        let found = await model.workspaces.resolve(name)
        guard !Task.isCancelled else {
            return
        }
        program = found.map { .found($0.path(percentEncoded: false)) } ?? .notFound((name as NSString).lastPathComponent)
    }
}
