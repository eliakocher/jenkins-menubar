import AppKit
import MenubarCore
import SwiftUI
import UniformTypeIdentifiers

/// The seven team values in their three sections, Jenkins, GitLab and Work Item Conventions, each field with its issue
/// under it (TEAM-01, `docs/design/settings-team.md`). Settings → Team shows them, and the welcome flow's Team step
/// shows the first two sections. Put it inside a grouped `Form`.
public struct TeamValueFields: View {
    @Binding private var values: TeamValues
    private let issues: [TeamValues.Key: String]
    private let onSubmit: () -> Void
    private let onLeave: (TeamValues.Key) -> Void
    private let showsConventions: Bool
    private let initialFocus: TeamValues.Key?
    @FocusState private var focused: TeamValues.Key?

    /// - Parameters:
    ///   - values: the values as typed, usually `SettingsStore.teamDraft`, which saves them once typing pauses
    ///   - issues: the issue to show under each field, like "Enter a URL that starts with https:// or http://"
    ///   - onSubmit: Return in a field, which saves now
    ///   - onLeave: a field lost the keyboard focus, after which its issue shows
    ///   - showsConventions: whether the Work Item Conventions section shows; the welcome flow leaves it out
    ///     (review WELCOME-08)
    ///   - initialFocus: the field that takes the keyboard focus when the fields appear (review WELCOME-05)
    public init(
        values: Binding<TeamValues>, issues: [TeamValues.Key: String], onSubmit: @escaping () -> Void = {},
        onLeave: @escaping (TeamValues.Key) -> Void = { _ in }, showsConventions: Bool = true,
        initialFocus: TeamValues.Key? = nil
    ) {
        _values = values
        self.issues = issues
        self.onSubmit = onSubmit
        self.onLeave = onLeave
        self.showsConventions = showsConventions
        self.initialFocus = initialFocus
    }

    public var body: some View {
        Section {
            field(.jenkinsJobURL)
        } header: {
            // The focus's watchers hang on a single view that always shows: the conventions may be left out, and a
            // modifier on a section may go to each of its rows (inferred).
            Text("Jenkins")
                .onChange(of: focused) { old, _ in
                    if let old {
                        onLeave(old)
                    }
                }
                .task {
                    if let initialFocus {
                        focused = initialFocus
                    }
                }
        } footer: {
            SettingsFooter(
                "The multibranch job that builds the GitLab project, as the browser shows it. Merge request builds are "
                    + "its MR-<number> jobs; Check in Accounts confirms that Jenkins knows it.")
        }
        Section {
            field(.gitLabURL)
            field(.gitLabProject)
        } header: {
            Text("GitLab")
        }
        if showsConventions {
            Section {
                field(.committedLabel)
                field(.slotLabelPrefix)
                field(.ignoredMergeRequestPrefix)
                field(.typeLabelPrefix)
            } header: {
                Text("Work Item Conventions")
            } footer: {
                SettingsFooter(
                    "Committed work items get a section of their own that the sort and the limit never cut. The slot "
                        + "label's value shows before a work item's title. Merge requests whose title starts with the "
                        + "prefix, like automatic cascades, don't count as work on a work item. The type label prefix "
                        + "labels the work items made from New Work Item, like type::Bug.")
            }
            Section {
                field(.slotReleaseWeekday)
                field(.slotCodeFreezeNth)
                field(.slotCodeFreezeWeekday)
                field(.slotEarlyAccessNth)
                field(.slotEarlyAccessWeekday)
                field(.slotWarnDays)
                field(.inProgressLabel)
                field(.slotPlanningURL)
            } header: {
                Text("Slots")
            } footer: {
                SettingsFooter(
                    "A slot label's value like 2026.51 is the ISO week of its release, on the release weekday in that week "
                        + "(slots before 2026.30 released on Thursday, so their dates are a few days off). The code freeze is "
                        + "the Nth weekday before the release, by default the 4th Friday; early access the 2nd Monday. "
                        + "Committed items without a merge request are flagged from the warning days before the code freeze, "
                        + "and the slot alert, if on in General, comes then. Empty values use the defaults. The in-progress "
                        + "label marks work items that are being worked on; empty finds a label like status::InProgress.")
            }
        }
    }

    @ViewBuilder
    private func field(_ key: TeamValues.Key) -> some View {
        TextField(Self.label(of: key), text: Binding(get: { values[key] }, set: { values[key] = $0 }),
                  prompt: Text(Self.prompt(of: key)))
            .focused($focused, equals: key)
            .onSubmit(onSubmit)
            .help(values[key])
        if let issue = issues[key] {
            StatusLine(.problem, issue)
        }
    }

    /// "Jenkins job URL", "GitLab URL", "Project", "Committed label", "Slot label prefix", "Ignored merge request
    /// prefix", "Type label prefix"
    static func label(of key: TeamValues.Key) -> String {
        switch key {
        case .jenkinsJobURL: "Jenkins job URL"
        case .gitLabURL: "GitLab URL"
        case .gitLabProject: "Project"
        case .committedLabel: "Committed label"
        case .slotLabelPrefix: "Slot label prefix"
        case .ignoredMergeRequestPrefix: "Ignored merge request prefix"
        case .typeLabelPrefix: "Type label prefix"
        case .slotReleaseWeekday: "Release weekday"
        case .slotCodeFreezeNth: "Code freeze: which weekday before"
        case .slotCodeFreezeWeekday: "Code freeze weekday"
        case .slotEarlyAccessNth: "Early access: which weekday before"
        case .slotEarlyAccessWeekday: "Early access weekday"
        case .slotWarnDays: "Warning, days before the freeze"
        case .inProgressLabel: "In-progress label"
        case .slotPlanningURL: "Slot planning URL"
        }
    }

    /// the example of `team.example.json`, or "Off" for an optional value
    static func prompt(of key: TeamValues.Key) -> String {
        switch key {
        case .jenkinsJobURL: "https://jenkins.example.com/job/project"
        case .gitLabURL: "https://gitlab.example.com"
        case .gitLabProject: "group/subgroup/project"
        case .committedLabel: "Off"
        case .slotLabelPrefix: "Off, like slot::"
        case .ignoredMergeRequestPrefix: "Off, like [cascade]"
        case .typeLabelPrefix: "Off, like type::"
        case .slotReleaseWeekday: "Monday"
        case .slotCodeFreezeNth: "4"
        case .slotCodeFreezeWeekday: "Friday"
        case .slotEarlyAccessNth: "2"
        case .slotEarlyAccessWeekday: "Monday"
        case .slotWarnDays: "3"
        case .inProgressLabel: "Auto, like status::InProgress"
        case .slotPlanningURL: "Off, like https://planning.example.com"
        }
    }
}

/// The result of Import… or Export…, under their buttons until the next edit, import or export.
struct TeamFileResult: Hashable {
    var kind: StatusKind
    var text: String
}

/// One project in Settings → Projects' list (PROJ-02).
struct ProjectRow: Hashable, Identifiable {
    var id: ProjectID
    /// the name, like `server`
    var name: String
    /// the GitLab path, like `group/server`
    var path: String
}

/// Settings → Projects' form (`docs/design/settings-team.md`, plan Phase 13): the projects with + and −, the problem
/// rows, the edited project's seven values, Import… and Export…. It draws only what it is given.
struct TeamSettingsForm: View {
    @Binding var values: TeamValues
    let issues: [TeamValues.Key: String]
    let problems: [String]
    let fileResult: TeamFileResult?
    /// whether any value is saved, which Export… needs
    let canExport: Bool
    /// the projects, the primary one first; the list shows from one project on, so + is always there
    var projects: [ProjectRow] = []
    /// the edited project
    var selected: ProjectID = .main
    var onSubmit: () -> Void = {}
    var onLeave: (TeamValues.Key) -> Void = { _ in }
    var onImport: () -> Void = {}
    var onExport: () -> Void = {}
    var onSelect: (ProjectID) -> Void = { _ in }
    var onAdd: () -> Void = {}
    var onRemove: () -> Void = {}

    var body: some View {
        Form {
            if !projects.isEmpty {
                projectList
            }
            SettingsProblemRows(problems)
            TeamValueFields(values: $values, issues: issues, onSubmit: onSubmit, onLeave: onLeave)
            Section {
                HStack {
                    Button("Import…", action: onImport)
                    Button("Export…", action: onExport)
                        .disabled(!canExport)
                    Spacer()
                }
                if let fileResult {
                    StatusLine(fileResult.kind, fileResult.text)
                }
            } footer: {
                SettingsFooter("A team file holds these values, never a token, so the team can share it.")
            }
        }
        .formStyle(.grouped)
    }

    private var projectList: some View {
        Section {
            ForEach(projects) { project in
                Button {
                    onSelect(project.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: project.name)
                            if project.path != project.name, !project.path.isEmpty {
                                Text(verbatim: project.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if project.id == selected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Edited")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Button("Add Project…", systemImage: "plus", action: onAdd)
                Button("Remove", systemImage: "minus", action: onRemove)
                    .disabled(selected == projects.first?.id)
                    .help(selected == projects.first?.id ? "The first project can't be removed" : "")
                Spacer()
            }
        } header: {
            Text("Projects")
        } footer: {
            SettingsFooter(
                "Each project watches one more Jenkins job, on the same Jenkins and GitLab as the first. The first "
                    + "project's GitLab values drive Merge Requests and Work Items. Click a project to edit it.")
        }
    }
}

/// The sheet of Add Project…: the required values, or a team file (PROJ-02).
struct AddProjectSheet: View {
    @Binding var values: TeamValues
    let error: String?
    var onImport: () -> Void = {}
    var onCancel: () -> Void = {}
    var onAdd: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TeamValueFields(values: $values, issues: [:], onSubmit: onAdd, initialFocus: .jenkinsJobURL)
                Section {
                    HStack {
                        Button("Import Team File…", action: onImport)
                        Spacer()
                    }
                    if let error {
                        StatusLine(.problem, error)
                    }
                } footer: {
                    SettingsFooter("A project uses the first project's Jenkins and GitLab, and their tokens.")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Project", action: onAdd)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!values.normalized().missing.isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
    }
}

/// Settings → Team, from the settings store. A field's issue shows once typing pauses or the field loses the focus,
/// not at every keystroke; leaving the pane saves what waits for typing to pause.
struct TeamPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ProjectsPipelines.self) private var pipelines
    @ViewState private var isTyping = false
    @ViewState private var isImporting = false
    /// the result of the last import or export, with the values it showed with, so the next edit hides it
    @ViewState private var fileResult: (result: TeamFileResult, values: TeamValues)?
    @ViewState private var isAdding = false
    @ViewState private var newProject = TeamValues()
    @ViewState private var addError: String?
    @ViewState private var isImportingNew = false
    @ViewState private var isConfirmingRemove = false

    var body: some View {
        @Bindable var settings = settings
        TeamSettingsForm(
            values: $settings.teamDraft, issues: isTyping ? [:] : issues, problems: problems,
            fileResult: fileResult.flatMap { $0.values == settings.teamDraft ? $0.result : nil },
            canExport: settings.team != TeamValues(),
            projects: projectRows, selected: settings.projectID,
            onSubmit: {
                isTyping = false
                settings.saveTeamNow()
            },
            onLeave: { _ in isTyping = false },
            onImport: { isImporting = true },
            onExport: export,
            onSelect: { id in
                isTyping = false
                fileResult = nil
                settings.selectProject(id)
            },
            onAdd: {
                newProject = TeamValues()
                addError = nil
                isAdding = true
            },
            onRemove: { isConfirmingRemove = true })
            .sheet(isPresented: $isAdding) {
                AddProjectSheet(
                    values: $newProject, error: addError,
                    onImport: { isImportingNew = true },
                    onCancel: { isAdding = false },
                    onAdd: addProject)
                    .fileImporter(isPresented: $isImportingNew, allowedContentTypes: [.json]) { result in
                        readNewProject(result)
                    }
            }
            .confirmationDialog(
                "Remove the project \(settings.projectName(settings.projectID))?", isPresented: $isConfirmingRemove
            ) {
                Button("Remove", role: .destructive) {
                    try? settings.removeProject(settings.projectID)
                }
            } message: {
                Text("Its watched and hidden builds go too. Its Jenkins job and GitLab project stay as they are.")
            }
            .onChange(of: settings.teamDraft) {
                isTyping = true
            }
            .task(id: settings.teamDraft) {
                // The same pause as the save (TEAM-01).
                try? await Task.sleep(for: SettingsStore.teamSaveDelay)
                if !Task.isCancelled {
                    isTyping = false
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                importFile(result)
            }
            .onDisappear {
                settings.saveTeamNow()
            }
    }

    private var issues: [TeamValues.Key: String] {
        var issues: [TeamValues.Key: String] = [:]
        for key in TeamValues.Key.allCases {
            issues[key] = settings.teamIssue(for: key)
        }
        return issues
    }

    private var projectRows: [ProjectRow] {
        settings.projects.map { ProjectRow(id: $0.id, name: settings.projectName($0.id), path: $0.team.gitLabProject) }
    }

    private func addProject() {
        do {
            try settings.addProject(newProject)
            isAdding = false
        } catch let error as ProjectError {
            addError = error.message
        } catch {
            addError = "The project could not be saved: \(error.localizedDescription)"
        }
    }

    /// Fills the sheet from a team file, so the values show before Add Project saves them.
    private func readNewProject(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            newProject = try TeamStore.readTeamFile(from: url)
            addError = nil
        } catch let error as TeamFileError {
            addError = error.message
        } catch {
            addError = error.localizedDescription
        }
    }

    private var problems: [String] {
        // The edited project's own problem: an unknown job, or missing values (TEAM-03).
        let problem = pipelines.store(for: settings.projectID)?.problem
        return SettingsProblemRows.texts(for: .team, from: [problem]) + [settings.teamError].compactMap { $0 }
    }

    private func importFile(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let outcome: TeamFileResult
        do {
            try settings.importTeamFile(from: url)
            outcome = TeamFileResult(kind: .ok, text: "Imported the team values from \(url.lastPathComponent)")
        } catch let error as TeamFileError {
            outcome = TeamFileResult(kind: .problem, text: error.message)
        } catch {
            outcome = TeamFileResult(kind: .problem, text: "The team values could not be saved: \(error.localizedDescription)")
        }
        fileResult = (outcome, settings.teamDraft)
    }

    /// Export… through the system's save panel: `fileExporter` would want a document type of its own (Unverified 2).
    /// The panel is a sheet on Settings, as Import…'s is (review SETTINGS-TEAM-01); at the click, Settings is the key
    /// window.
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "team.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let completion = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                exportFile(to: url)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func exportFile(to url: URL) {
        let outcome: TeamFileResult
        do {
            try settings.exportTeamFile(to: url)
            outcome = TeamFileResult(kind: .ok, text: "Exported the team values to \(url.lastPathComponent)")
        } catch {
            outcome = TeamFileResult(kind: .problem, text: "The team file could not be written: \(error.localizedDescription)")
        }
        fileResult = (outcome, settings.teamDraft)
    }
}
