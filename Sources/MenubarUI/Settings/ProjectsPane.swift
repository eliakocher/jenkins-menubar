import MenubarCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Projects' form (PROJ-02): the watched projects with Add and Remove, then the selected one's Jenkins job
/// and GitLab project. The team's conventions and the slot values live in Team, once, for every project. It draws only
/// what it is given.
struct ProjectsSettingsForm: View {
    @Binding var values: TeamValues
    let issues: [TeamValues.Key: String]
    var problems: [String] = []
    /// the projects, the primary one first
    let projects: [ProjectRow]
    /// the edited project
    var selected: ProjectID = .main
    var onSubmit: () -> Void = {}
    var onSelect: (ProjectID) -> Void = { _ in }
    var onAdd: () -> Void = {}
    var onRemove: () -> Void = {}

    var body: some View {
        Form {
            SettingsPaneHeader(pane: .projects)
            SettingsProblemRows(problems)
            Section {
                ForEach(projects) { project in
                    ProjectListRow(
                        project: project, isPrimary: project.id == projects.first?.id, isSelected: project.id == selected
                    ) {
                        onSelect(project.id)
                    }
                    .settingsAnchor(.projects, enabled: project.id == projects.first?.id)
                }
                HStack(spacing: 8) {
                    Button("Add Project…", systemImage: "plus", action: onAdd)
                    Button("Remove", systemImage: "minus", action: onRemove)
                        .disabled(selected == projects.first?.id)
                        .help(selected == projects.first?.id ? "The first project can't be removed" : "")
                    Spacer()
                }
            } header: {
                SettingsSectionHeader("Watched Projects", shared: true)
            } footer: {
                SettingsFooter(
                    "Each project watches one Jenkins job. All of them use the same Jenkins and GitLab, and your tokens; "
                        + "the first one's GitLab project feeds Merge Requests and Work Items.")
            }
            Section {
                SettingsTextRow(
                    "Jenkins job", caption: "The multibranch job, as the browser shows it",
                    text: binding(.jenkinsJobURL), prompt: TeamValueFields.prompt(of: .jenkinsJobURL),
                    issue: issues[.jenkinsJobURL], stacked: true)
                .settingsAnchor(.jenkinsJob)
                SettingsTextRow(
                    "GitLab project", text: binding(.gitLabProject),
                    prompt: TeamValueFields.prompt(of: .gitLabProject), issue: issues[.gitLabProject], width: 300)
            } header: {
                SettingsSectionHeader(selectedName, shared: true)
            }
        }
        .formStyle(.grouped)
        .revealsSettingsFields()
        .onSubmit(onSubmit)
    }

    private var selectedName: String {
        projects.first { $0.id == selected }?.name ?? "Project"
    }

    private func binding(_ key: TeamValues.Key) -> Binding<String> {
        Binding(get: { values[key] }, set: { values[key] = $0 })
    }
}

/// A project in the list: its name, its GitLab path, "Primary" on the first, and a check on the edited one.
private struct ProjectListRow: View {
    let project: ProjectRow
    let isPrimary: Bool
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(verbatim: project.name)
                            .fontWeight(isSelected ? .semibold : .regular)
                        if isPrimary {
                            Text("Primary")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    if project.path != project.name, !project.path.isEmpty {
                        Text(verbatim: project.path)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Edited")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The sheet of Add Project…: its Jenkins job and GitLab project, or a team file; the GitLab URL is the first
/// project's (PROJ-02).
struct AddProjectSheet: View {
    @Binding var values: TeamValues
    let error: String?
    var onImport: () -> Void = {}
    var onCancel: () -> Void = {}
    var onAdd: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    SettingsTextRow(
                        "Jenkins job", caption: "The multibranch job that builds it, as the browser shows it",
                        text: $values.jenkinsJobURL, prompt: TeamValueFields.prompt(of: .jenkinsJobURL), stacked: true)
                    SettingsTextRow(
                        "GitLab project", caption: "Its path on GitLab", text: $values.gitLabProject,
                        prompt: TeamValueFields.prompt(of: .gitLabProject), width: 260)
                    if let error {
                        StatusLine(.problem, error)
                    }
                } header: {
                    SettingsSectionHeader("Add a Project")
                } footer: {
                    SettingsFooter("It uses the first project's Jenkins and GitLab, and your tokens.")
                }
            }
            .formStyle(.grouped)
            .onSubmit(onAdd)
            HStack {
                Button("Import Team File…", action: onImport)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Project", action: onAdd)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!values.normalized().missing.isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 330)
    }
}

/// Settings → Projects, from the settings store. A field's issue shows once typing pauses, not at every keystroke;
/// leaving the pane saves what waits for typing to pause.
struct ProjectsPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ProjectsPipelines.self) private var pipelines
    @ViewState private var isTyping = false
    @ViewState private var isAdding = false
    @ViewState private var newProject = TeamValues()
    @ViewState private var addError: String?
    @ViewState private var isImportingNew = false
    @ViewState private var isConfirmingRemove = false

    var body: some View {
        @Bindable var settings = settings
        ProjectsSettingsForm(
            values: $settings.teamDraft, issues: isTyping ? [:] : settings.teamIssues, problems: problems,
            projects: projectRows, selected: settings.projectID,
            onSubmit: {
                isTyping = false
                settings.saveTeamNow()
            },
            onSelect: { id in
                isTyping = false
                settings.selectProject(id)
            },
            onAdd: {
                // The first project's GitLab, the only one a project may use.
                newProject = TeamValues(gitLabURL: settings.primaryTeam.gitLabURL)
                addError = nil
                isAdding = true
            },
            onRemove: { isConfirmingRemove = true })
            .modifier(TeamDraftTyping(draft: settings.teamDraft, isTyping: $isTyping))
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
            .onDisappear {
                settings.saveTeamNow()
            }
    }

    private var projectRows: [ProjectRow] {
        // Before anything is saved, the primary project shows on its own, so Add and its fields are there.
        let projects = settings.projects.isEmpty ? [Project(id: settings.projectID, team: settings.team)] : settings.projects
        return projects.map { ProjectRow(id: $0.id, name: settings.projectName($0.id), path: $0.team.gitLabProject) }
    }

    private var problems: [String] {
        // The edited project's own problem: an unknown job, or missing values (TEAM-03).
        let problem = pipelines.store(for: settings.projectID)?.problem
        return SettingsProblemRows.texts(for: .projects, from: [problem]) + [settings.teamError].compactMap { $0 }
    }

    private func addProject() {
        guard newProject.normalized().missing.isEmpty else { return }
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
        do {
            newProject = try withSecurityScope(url) { try TeamStore.readTeamFile(from: url) }
            addError = nil
        } catch let error as TeamFileError {
            addError = error.message
        } catch {
            addError = error.localizedDescription
        }
    }
}
