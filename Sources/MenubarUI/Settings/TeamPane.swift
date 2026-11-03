import AppKit
import MenubarCore
import SwiftUI
import UniformTypeIdentifiers

/// The labels and the example values of the team values in Settings, Team and the welcome flow.
extension TeamValues.Key {
    /// "Jenkins job URL", "GitLab URL", "Project", "Committed label", "Slot label prefix", "Ignored merge request
    /// prefix", "Type label prefix"
    var label: String {
        switch self {
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
        case .slotUpcomingShown: "Upcoming slots shown"
        case .slotPastShown: "Past slots shown"
        case .inProgressLabel: "In-progress label"
        case .slotPlanningURL: "Slot planning URL"
        case .slotGroup: "Slot group"
        case .slotScheduledLabelPrefix: "Scheduled slot label prefix"
        case .squadLabelPrefix: "Squad label prefix"
        case .statusLabelPrefix: "Status label prefix"
        case .squadCapacity: "Squad capacity, points per slot"
        case .blockedLabel: "Blocked label"
        case .sizeLabelPrefix: "Size label prefix"
        case .priorityLabelPrefix: "Priority label prefix"
        case .slotTeams: "Teams and their members"
        case .slotMemberWorkDays: "Work days per week"
        case .slotCommitmentGroup: "Commitment group"
        }
    }

    /// the example of `team.example.json`, or "Off" for an optional value
    var prompt: String {
        switch self {
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
        case .slotUpcomingShown: "4"
        case .slotPastShown: "2"
        case .inProgressLabel: "Auto, like status::InProgress"
        case .slotPlanningURL: "Off, like https://planning.example.com"
        case .slotGroup: "Off, like group"
        case .slotScheduledLabelPrefix: "Off, like slot-scheduled::"
        case .squadLabelPrefix: "Off, like squad::"
        case .statusLabelPrefix: "Off, like status::"
        case .squadCapacity: "Off, like Alpha: 60, Delta: 120"
        case .blockedLabel: "GitLab's, like prerequisite::Blocked"
        case .sizeLabelPrefix: "Off, like size::"
        case .priorityLabelPrefix: "Off, like priority::"
        case .slotTeams: "Squad labels, like Alpha: user1, user2; Bravo: user3"
        case .slotMemberWorkDays: "5 each, like user1: 4, user2: 3"
        case .slotCommitmentGroup: "Off, like group/commitments"
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

/// Settings → Team's form: the banner that says these values are the team's, with Import… and Export… of the team
/// file, then the labels, the slot schedule, slot planning and squads, each section marked as shared. It edits the
/// primary project's values, the only ones Slots and the conventions read. It draws only what it is given.
struct TeamSettingsForm: View {
    @Binding var values: TeamValues
    let issues: [TeamValues.Key: String]
    var problems: [String] = []
    let fileResult: TeamFileResult?
    /// whether any value is saved, which Export… needs
    let canExport: Bool
    var onSubmit: () -> Void = {}
    var onImport: () -> Void = {}
    var onExport: () -> Void = {}
    var linkActions = TeamFileLinkActions()

    var body: some View {
        Form {
            SettingsPaneHeader(pane: .team)
            SettingsProblemRows(problems)
            TeamFileBanner(
                fileResult: fileResult, canExport: canExport, onImport: onImport, onExport: onExport,
                linkActions: linkActions)
            Section {
                row(.committedLabel, "Gets a section of its own in Work Items")
                    .settingsAnchor(.labels)
                row(.inProgressLabel, "Empty finds one like status::InProgress")
                row(.statusLabelPrefix, "Gives a work item's status")
                row(.typeLabelPrefix, "For New Work Item, like type::Bug")
                row(
                    .ignoredMergeRequestPrefix,
                    "Titles starting with it don't count as work")
                row(.blockedLabel, "Empty reads GitLab's own blocked flag")
                row(.sizeLabelPrefix, "The size of epics: S, M, L or XL")
                row(.priorityLabelPrefix, "Sorts a slot's items, Blocker first")
            } header: {
                SettingsSectionHeader("Labels", shared: true)
            }
            Section {
                row(.slotLabelPrefix, "The due slot, like 2026.51: the ISO week of its release")
                    .settingsAnchor(.slotSchedule)
                LabeledContent {
                    WeekdayPicker(text: binding(.slotReleaseWeekday), standard: SlotRules.defaultReleaseWeekday)
                } label: {
                    SettingsRowLabel("Release day")
                }
                anchorRow(
                    "Code freeze", nth: .slotCodeFreezeNth, weekday: .slotCodeFreezeWeekday,
                    standard: SlotRules.defaultCodeFreeze)
                anchorRow(
                    "Early access", nth: .slotEarlyAccessNth, weekday: .slotEarlyAccessWeekday,
                    standard: SlotRules.defaultEarlyAccess)
                LabeledContent {
                    NumberPicker(
                        text: binding(.slotWarnDays), options: Array(0...14) + [21, 30],
                        standard: SlotRules.defaultWarnDays, title: { $0 == 1 ? "1 day" : "\($0) days" })
                } label: {
                    SettingsRowLabel(
                        "Warn before the freeze", "Flags committed items without a merge request")
                }
                LabeledContent {
                    NumberPicker(
                        text: binding(.slotUpcomingShown), options: Array(1...12),
                        standard: SlotRules.defaultUpcomingShown, title: { "\($0)" })
                } label: {
                    SettingsRowLabel("Upcoming slots shown")
                }
                LabeledContent {
                    NumberPicker(
                        text: binding(.slotPastShown), options: Array(0...12),
                        standard: SlotRules.defaultPastShown, title: { "\($0)" })
                } label: {
                    SettingsRowLabel("Past slots shown", "The latest released ones, besides any with open items")
                }
                ForEach([TeamValues.Key.slotReleaseWeekday, .slotCodeFreezeNth, .slotCodeFreezeWeekday,
                         .slotEarlyAccessNth, .slotEarlyAccessWeekday, .slotWarnDays, .slotUpcomingShown, .slotPastShown],
                        id: \.self) { key in
                    if let issue = issues[key] {
                        StatusLine(.problem, "\(key.label): \(issue)")
                    }
                }
            } header: {
                SettingsSectionHeader("Slot Schedule", shared: true)
            } footer: {
                SettingsFooter("Slots before 2026.30 released on Thursday, so their dates are a few days off.")
            }
            Section {
                row(.slotGroup, "Slots shows the issues of it and its subgroups")
                    .settingsAnchor(.slotPlanning)
                row(.slotScheduledLabelPrefix, "An item's slot, committed or not; empty takes the due slot")
                row(.slotCommitmentGroup, "Its epics are the team's commitments, the top of a slot")
                row(.slotPlanningURL, "The team's planning page")
            } header: {
                SettingsSectionHeader("Slot Planning", shared: true)
            }
            Section {
                row(.squadLabelPrefix, "Gives the squad chips")
                    .settingsAnchor(.squads)
                SettingsTextRow(
                    TeamValues.Key.slotTeams.label, caption: "GitLab usernames per team; empty takes the squad labels",
                    text: binding(.slotTeams), prompt: TeamValues.Key.slotTeams.prompt, issue: issues[.slotTeams],
                    stacked: true)
                row(.slotMemberWorkDays, "Only for whoever doesn't work 5 days")
                row(.squadCapacity, "Points per slot, for the load")
            } header: {
                SettingsSectionHeader("Teams and Squads", shared: true)
            }
        }
        .formStyle(.grouped)
        .revealsSettingsFields()
        .onSubmit(onSubmit)
    }

    private func binding(_ key: TeamValues.Key) -> Binding<String> {
        Binding(get: { values[key] }, set: { values[key] = $0 })
    }

    private func row(_ key: TeamValues.Key, _ caption: String) -> some View {
        SettingsTextRow(
            key.label, caption: caption, text: binding(key), prompt: key.prompt,
            issue: issues[key], width: 220)
    }

    /// "Code freeze: [4th] [Friday] before the release", two pickers on one row.
    private func anchorRow(
        _ title: String, nth: TeamValues.Key, weekday: TeamValues.Key, standard: SlotRules.Anchor
    ) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                NumberPicker(text: binding(nth), options: Array(1...12), standard: standard.nth, title: Self.ordinal)
                WeekdayPicker(text: binding(weekday), standard: standard.weekday)
            }
        } label: {
            SettingsRowLabel(title, "Before the release day")
        }
    }

    /// "1st", "2nd", "4th"
    static func ordinal(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: number as NSNumber) ?? "\(number)"
    }
}

/// Settings → Team's team file row: Import… (from a file or a link), Export… and Share Setup…, and what the last one
/// did.
struct TeamFileBanner: View {
    let fileResult: TeamFileResult?
    let canExport: Bool
    var onImport: () -> Void = {}
    var onExport: () -> Void = {}
    var linkActions = TeamFileLinkActions()
    @ViewState private var anchor = ShareAnchorBox()
    @ViewState private var copied = false

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    Menu("Import…") {
                        Button("From a File…", action: onImport)
                        Button("From a Link…", action: linkActions.onImportLink)
                    }
                    .fixedSize()
                    Button("Export…", action: onExport)
                        .disabled(!canExport)
                    Menu("Share Setup…") {
                        Button("Share Team File…", action: share)
                            .disabled(!canExport)
                        Button("Copy Import Link", action: copyLink)
                            .disabled(!linkActions.canCopyLink)
                            .help(Self.copyHelp(canCopy: linkActions.canCopyLink))
                    }
                    .fixedSize()
                    .background(ShareAnchor(box: anchor))
                }
            } label: {
                SettingsRowLabel("Team file", "Edits stay on this Mac until you export and share it")
            }
            .settingsAnchor(.teamFile)
            if let fileResult {
                StatusLine(fileResult.kind, fileResult.text)
            }
        }
    }

    static func copyHelp(canCopy: Bool) -> String {
        let text = "Colleagues click it to preview your team file; it holds only the link, never a token"
        return canCopy ? text : "Import a team file from a link first. " + text
    }

    private func share() {
        guard let url = linkActions.onShare() else { return }
        anchor.present(url)
    }

    private func copyLink() {
        guard linkActions.onCopyLink() else { return }
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copied = false }
        }
    }
}

/// A weekday as a team value: the menu shows a day, the default one for an empty value; picking the default empties
/// the value, so the team file holds only what differs.
struct WeekdayPicker: View {
    @Binding var text: String
    /// the ISO weekday an empty value stands for
    let standard: Int

    private static let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var body: some View {
        Picker("Weekday", selection: Binding(
            get: { SlotRules.weekday(of: text) ?? standard },
            set: { text = $0 == standard ? "" : Self.names[$0 - 1] }
        )) {
            ForEach(1...7, id: \.self) { day in
                Text(verbatim: Self.names[day - 1]).tag(day)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}

/// A number as a team value, from a list of options: the menu shows the default for an empty value, and keeps a value
/// outside the options as one more; picking the default empties the value.
struct NumberPicker: View {
    @Binding var text: String
    let options: [Int]
    /// the number an empty value stands for
    let standard: Int
    let title: (Int) -> String

    var body: some View {
        let current = SlotRules.days(of: text) ?? standard
        Picker("Number", selection: Binding(
            get: { current },
            set: { text = $0 == standard ? "" : String($0) }
        )) {
            ForEach((options.contains(current) ? options : (options + [current]).sorted()), id: \.self) { number in
                Text(verbatim: title(number)).tag(number)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}

/// Shows a team value's issue only once typing pauses or the field loses the focus, not at every keystroke (TEAM-01):
/// `isTyping` goes on at each edit and off after the same pause as the save.
struct TeamDraftTyping: ViewModifier {
    let draft: TeamValues
    @Binding var isTyping: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: draft) {
                isTyping = true
            }
            .task(id: draft) {
                try? await Task.sleep(for: SettingsStore.teamSaveDelay)
                if !Task.isCancelled {
                    isTyping = false
                }
            }
    }
}

extension SettingsStore {
    /// the issue under each team value as it is typed now
    var teamIssues: [TeamValues.Key: String] {
        var issues: [TeamValues.Key: String] = [:]
        for key in TeamValues.Key.allCases {
            issues[key] = teamIssue(for: key)
        }
        return issues
    }
}

/// Runs a file panel's result with access to the file, as a sandboxed app needs it.
func withSecurityScope<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
        if scoped {
            url.stopAccessingSecurityScopedResource()
        }
    }
    return try body()
}

/// Settings → Team, from the settings store: always the primary project's values. Leaving the pane saves what waits
/// for typing to pause.
struct TeamPane: View {
    @Environment(SettingsStore.self) private var settings
    @ViewState private var isTyping = false
    @ViewState private var isImporting = false
    /// the result of the last import or export, with the values it showed with, so the next edit hides it
    @ViewState private var fileResult: (result: TeamFileResult, values: TeamValues)?
    /// Import from a Link…'s sheet while it shows
    @ViewState private var linkRequest: TeamFileLinkSheet.Request?

    var body: some View {
        @Bindable var settings = settings
        TeamSettingsForm(
            values: $settings.teamDraft, issues: isTyping ? [:] : settings.teamIssues,
            problems: [settings.teamError].compactMap { $0 },
            fileResult: fileResult.flatMap { $0.values == settings.teamDraft ? $0.result : nil },
            canExport: settings.team != TeamValues(),
            onSubmit: {
                isTyping = false
                settings.saveTeamNow()
            },
            onImport: { isImporting = true },
            onExport: export,
            linkActions: TeamFileLinkActions(
                canCopyLink: settings.teamFileLink.flatMap(TeamFileImport.shareLink(for:)) != nil,
                onImportLink: {
                    linkRequest = TeamFileLinkSheet.Request(
                        link: settings.teamFileLink?.absoluteString ?? "", fetchesAtOnce: false)
                },
                onShare: shareFile, onCopyLink: copyImportLink))
            .modifier(TeamDraftTyping(draft: settings.teamDraft, isTyping: $isTyping))
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                importFile(result)
            }
            .sheet(item: $linkRequest) { request in
                TeamFileLinkSheet(
                    request: request,
                    onApplied: { host in
                        linkRequest = nil
                        fileResult = (
                            TeamFileResult(kind: .ok, text: "Imported the team values from \(host)"), settings.teamDraft)
                    },
                    onCancel: { linkRequest = nil })
            }
            .onAppear {
                settings.editPrimaryProject()
                openPendingLink()
            }
            .onChange(of: settings.pendingTeamFileLink) {
                openPendingLink()
            }
            .onDisappear {
                settings.saveTeamNow()
            }
    }

    /// An import link from outside (`megamonitor://import?url=…`) opens the sheet and fetches its preview at once;
    /// nothing is applied before the user's click on Apply.
    private func openPendingLink() {
        guard let link = settings.pendingTeamFileLink else { return }
        settings.teamFileImportRequested()
        linkRequest = TeamFileLinkSheet.Request(link: link.absoluteString, fetchesAtOnce: true)
    }

    /// Share Team File…: the team values, without a token, as a temporary `team.json` for the sharing picker.
    private func shareFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("team.json")
        do {
            try settings.exportTeamFile(to: url)
            return url
        } catch {
            fileResult = (
                TeamFileResult(kind: .problem, text: "The team file could not be written: \(error.localizedDescription)"),
                settings.teamDraft)
            return nil
        }
    }

    /// Copy Import Link: `megamonitor://import?url=…` for the link the team values came from.
    private func copyImportLink() -> Bool {
        guard let link = settings.teamFileLink, let share = TeamFileImport.shareLink(for: link) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(share.absoluteString, forType: .string)
    }

    /// From a File…: reads the file and shows the same preview as an import link; nothing is applied before the click
    /// on Apply, and a changed server host only after the user trusted it by name (TEAM-02).
    private func importFile(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        do {
            let preview = try withSecurityScope(url) { try settings.previewTeamFile(from: url) }
            linkRequest = TeamFileLinkSheet.Request(
                link: "", fetchesAtOnce: false,
                file: TeamFileLinkSheet.PreviewedFile(name: url.lastPathComponent, preview: preview))
        } catch let error as TeamFileError {
            fileResult = (TeamFileResult(kind: .problem, text: error.message), settings.teamDraft)
        } catch {
            fileResult = (
                TeamFileResult(kind: .problem, text: "The team file could not be read: \(error.localizedDescription)"),
                settings.teamDraft)
        }
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
