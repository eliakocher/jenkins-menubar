import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
	case jenkins, gitlab, accounts, team

	var id: String { rawValue }

	var title: String {
		switch self {
		case .jenkins: "Jenkins"
		case .gitlab: "GitLab"
		case .accounts: "Accounts"
		case .team: "Team"
		}
	}

	var symbol: String {
		switch self {
		case .jenkins: "hammer.fill"
		case .gitlab: "arrow.triangle.merge"
		case .accounts: "key.fill"
		case .team: "person.2.fill"
		}
	}

	var color: Color {
		switch self {
		case .jenkins: .blue
		case .gitlab: .orange
		case .accounts: .gray
		case .team: .green
		}
	}
}

@MainActor
final class Navigation: ObservableObject {
	@Published var pane: Pane? = .jenkins
}

struct SettingsView: View {
	@ObservedObject var model: SettingsModel
	@ObservedObject var navigation: Navigation

	var body: some View {
		NavigationSplitView {
			List(Pane.allCases, selection: $navigation.pane) { pane in
				Label {
					Text(pane.title)
				} icon: {
					Image(systemName: pane.symbol)
						.font(.system(size: 11, weight: .semibold))
						.foregroundStyle(.white)
						.frame(width: 20, height: 20)
						.background(RoundedRectangle(cornerRadius: 5).fill(pane.color.gradient))
				}
				.tag(pane)
			}
			.navigationSplitViewColumnWidth(190)
			.toolbar(removing: .sidebarToggle)
		} detail: {
			let pane = navigation.pane ?? .jenkins
			Group {
				switch pane {
				case .jenkins: JenkinsPane(model: model)
				case .gitlab: GitLabPane(model: model)
				case .accounts: AccountsPane(model: model)
				case .team: TeamPane(model: model)
				}
			}
			.formStyle(.grouped)
			.navigationTitle(pane.title)
			.safeAreaInset(edge: .bottom) {
				if let problem = model.problem {
					Label(problem, systemImage: "exclamationmark.triangle.fill")
						.foregroundStyle(.red)
						.padding(10)
						.frame(maxWidth: .infinity)
						.background(.bar)
				}
			}
		}
	}
}

/// A picker for a setting with fixed options; a hand-edited value that is not one of them still shows.
struct Choice: View {
	let title: String
	@Binding var value: String
	let options: [(value: String, label: String)]

	init(_ title: String, value: Binding<String>, _ options: [(value: String, label: String)]) {
		self.title = title
		self._value = value
		self.options = options
	}

	var body: some View {
		Picker(title, selection: $value) {
			ForEach(shownOptions, id: \.value) { option in
				Text(option.label).tag(option.value)
			}
		}
	}

	private var shownOptions: [(value: String, label: String)] {
		options.contains { $0.value == value } ? options : options + [(value, "\(value) (from the settings file)")]
	}
}

// ── Jenkins builds ──

struct JenkinsPane: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		Form {
			Section {
				Choice("Check Jenkins every", value: model.setting("refresh_seconds"), [
					("30", "30 seconds"), ("60", "1 minute"), ("120", "2 minutes"), ("300", "5 minutes"), ("600", "10 minutes"),
				])
			}
			Section("Finished builds") {
				Choice("Hide successful builds after", value: model.setting("hide_successful_after_hours"), [
					("immediately", "Immediately"), ("1", "1 hour"), ("8", "8 hours"), ("24", "1 day"), ("72", "3 days"), ("168", "1 week"),
					("0", "Never"),
				])
				Choice("Hide failed builds after", value: model.setting("hide_failed_after_hours"), [
					("immediately", "Immediately"), ("24", "1 day"), ("72", "3 days"), ("168", "1 week"), ("336", "2 weeks"), ("0", "Never"),
				])
				Toggle("Hide the builds of merged merge requests", isOn: model.flag("hide_merged"))
			}
			Section {
				Picker("Alert", selection: model.setting("alert")) {
					Text("Big alert").tag("dialog")
					Text("Banner").tag("banner")
				}
				.pickerStyle(.segmented)
				Toggle("Say the result out loud", isOn: model.flag("voice"))
				Toggle("Show a banner as soon as a stage fails", isOn: model.flag("stage_alerts"))
				LabeledContent("Preview") {
					HStack {
						Button("Success") { model.previewAlert(success: true) }
						Button("Failure") { model.previewAlert(success: false) }
					}
				}
			} header: {
				Text("When a build finishes")
			} footer: {
				Text("The big alert stays on screen until you dismiss it; the banner goes away by itself and waits in the Notification Center.")
					.foregroundStyle(.secondary)
			}
			Section("Menubar") {
				Choice("Icons", value: model.setting("menubar_icons"), [("monochrome", "Black and white"), ("emoji", "Colored emoji")])
			}
			Section {
				Button("Open the Settings File") { model.openInEditor(model.snapshot?.files.settings) }
			} footer: {
				Text("Hand edits to the settings file work too.")
					.foregroundStyle(.secondary)
			}
		}
	}
}

// ── GitLab ──

struct GitLabPane: View {
	@ObservedObject var model: SettingsModel
	@State private var query = ""

	var body: some View {
		Form {
			Section {
				Choice("Check GitLab every", value: model.setting("gitlab_refresh_seconds"), [
					("60", "1 minute"), ("120", "2 minutes"), ("300", "5 minutes"), ("600", "10 minutes"), ("1800", "30 minutes"),
				])
			} footer: {
				Text("For the merge requests and the work items.")
					.foregroundStyle(.secondary)
			}
			Section("Work items") {
				Choice("Show", value: model.setting("work_items_scope"), [("assigned", "Assigned to me"), ("authored", "Created by me")])
				Choice("Type", value: model.setting("work_items_type"), [
					("all", "All"), ("ISSUE", "Issues"), ("TASK", "Tasks"), ("EPIC", "Epics"), ("INCIDENT", "Incidents"),
				])
				Choice("State", value: model.setting("work_items_state"), [("opened", "Open"), ("closed", "Closed"), ("all", "Open and closed")])
				Choice("Sort by", value: model.setting("work_items_sort"), [
					("UPDATED_DESC", "Recently updated"), ("CREATED_DESC", "Recently created"), ("CREATED_ASC", "Oldest first"),
					("DUE_DATE_ASC", "Due date"), ("TITLE_ASC", "Title"), ("WEIGHT_DESC", "Weight"), ("PRIORITY_ASC", "Priority"),
				])
				Choice("Show at most", value: model.setting("work_items_limit"), [("10", "10"), ("20", "20"), ("30", "30"), ("50", "50"), ("100", "100")])
			}
			Section {
				if !(model.withLabels + model.withoutLabels).isEmpty {
					LabeledContent("Filtering by") {
						HStack {
							ForEach(model.withLabels, id: \.self) { label in LabelPill(name: label, mark: "+") }
							ForEach(model.withoutLabels, id: \.self) { label in LabelPill(name: label, mark: "−") }
						}
					}
				}
				TextField("Search", text: $query, prompt: Text("Search labels"))
					.labelsHidden()
				if shownLabels.isEmpty {
					Text(model.labels.isEmpty ? "No labels yet: they come with the work items GitLab shows." : "No label matches.")
						.foregroundStyle(.secondary)
				}
				ForEach(shownLabels, id: \.self) { label in
					LabeledContent {
						Picker("Filter", selection: model.labelFilter(label)) {
							Text("Any").tag(LabelFilter.any)
							Text("With").tag(LabelFilter.with)
							Text("Without").tag(LabelFilter.without)
						}
						.pickerStyle(.segmented)
						.labelsHidden()
						.fixedSize()
					} label: {
						LabelPill(name: label)
					}
				}
			} header: {
				HStack {
					Text("Labels")
					Spacer()
					if !(model.withLabels + model.withoutLabels).isEmpty {
						Button("Clear Label Filters") { model.clearLabelFilters() }
							.buttonStyle(.link)
							.font(.callout)
					}
				}
			} footer: {
				Text("Work items need every “With” label and none of the “Without” ones. The list has the labels of the work items GitLab showed in the last 30 days.")
					.foregroundStyle(.secondary)
			}
		}
	}

	private var shownLabels: [String] {
		let query = query.trimmingCharacters(in: .whitespaces)
		return query.isEmpty ? model.labels : model.labels.filter { $0.localizedCaseInsensitiveContains(query) }
	}
}

/// A label the way GitLab draws it: a scoped label (scope::value) as a two-part pill; the mark (+ or −) goes first.
struct LabelPill: View {
	let name: String
	var mark: String?

	var body: some View {
		let parts = name.components(separatedBy: "::")
		HStack(spacing: 0) {
			if let mark {
				Text(mark)
					.bold()
					.padding(.leading, 7)
			}
			if parts.count > 1 {
				Text(parts[0])
					.padding(.horizontal, 7)
					.background(Color.secondary.opacity(0.28))
				Text(parts.dropFirst().joined(separator: "::"))
					.padding(.horizontal, 7)
			} else {
				Text(name)
					.padding(.horizontal, 7)
			}
		}
		.font(.callout)
		.padding(.vertical, 2)
		.background(Color.secondary.opacity(0.12))
		.clipShape(Capsule())
	}
}

// ── Accounts ──

struct AccountsPane: View {
	@ObservedObject var model: SettingsModel
	@State private var jenkinsUser = ""
	@State private var jenkinsToken = ""
	@State private var gitlabToken = ""

	var body: some View {
		Form {
			Section("Jenkins") {
				TokenSource(token: model.token("jenkins"))
				TextField("User", text: $jenkinsUser, prompt: Text("Your Jenkins user"))
				SecureField("New API token", text: $jenkinsToken, prompt: Text("Paste the API token"))
				HStack {
					if let link = model.snapshot?.links.jenkinsToken.flatMap(URL.init(string:)) {
						Link("Get a token: your user page → Security", destination: link)
							.font(.callout)
					}
					Spacer()
					if model.token("jenkins")?.source == "keychain" {
						Button("Remove", role: .destructive) { model.deleteToken("JENKINS_MCP_BASIC_AUTH") }
					}
					Button("Save in the Keychain") {
						if model.saveJenkinsToken(user: jenkinsUser, token: jenkinsToken) {
							jenkinsToken = ""
						}
					}
					.disabled(jenkinsUser.trimmingCharacters(in: .whitespaces).isEmpty || jenkinsToken.isEmpty)
				}
			}
			Section("GitLab") {
				TokenSource(token: model.token("gitlab"))
				SecureField("New token", text: $gitlabToken, prompt: Text("Paste a token with the read_api scope"))
				HStack {
					if let link = model.snapshot?.links.gitlabToken.flatMap(URL.init(string:)) {
						Link("Create a token with the read_api scope", destination: link)
							.font(.callout)
					}
					Spacer()
					if model.token("gitlab")?.source == "keychain" {
						Button("Remove", role: .destructive) { model.deleteToken("GITLAB_TOKEN") }
					}
					Button("Save in the Keychain") {
						if model.saveGitLabToken(gitlabToken) {
							gitlabToken = ""
						}
					}
					.disabled(gitlabToken.isEmpty)
				}
			}
			Section {
				LabeledContent("Connection") {
					if model.checkingAccounts {
						ProgressView().controlSize(.small)
					} else {
						Button("Check") { model.checkAccounts() }
					}
				}
				if let check = model.accountCheck {
					CheckResult(title: "Jenkins", result: check.jenkins)
					CheckResult(title: "GitLab", result: check.gitlab)
				}
			} footer: {
				Text("Tokens saved here go to your login keychain (as jenkins-menubar), not to a file. The menu also reads plain exports in ~/.zshrc.")
					.foregroundStyle(.secondary)
			}
		}
		.onAppear {
			if jenkinsUser.isEmpty {
				jenkinsUser = model.token("jenkins")?.user ?? ""
			}
		}
	}
}

struct TokenSource: View {
	let token: Snapshot.Token?

	var body: some View {
		LabeledContent("Current token") {
			switch token?.source {
			case "keychain": Label("In the keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
			case "zshrc": Label("Read from ~/.zshrc", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
			case "environment": Label("From the environment", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
			case "zshrc-computed":
				Label("~/.zshrc computes it, which the menu cannot run: save it here", systemImage: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange)
			default: Label("Missing", systemImage: "xmark.circle.fill").foregroundStyle(.red)
			}
		}
	}
}

struct CheckResult: View {
	let title: String
	let result: AccountCheck.Result

	var body: some View {
		LabeledContent(title) {
			Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
				.foregroundStyle(result.ok ? .green : .red)
		}
	}
}

// ── Team ──

/// A text field for a long value like a URL: the title above, the field across the whole row.
struct WideField: View {
	let title: String
	@Binding var text: String
	let prompt: String

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(title)
			TextField(title, text: $text, prompt: Text(prompt))
				.labelsHidden()
				.textFieldStyle(.roundedBorder)
		}
	}
}

struct TeamPane: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		Form {
			Section {
				WideField(title: "Multibranch job", text: model.teamValue("jenkins_job_url"), prompt: "https://jenkins.example.com/job/project")
			} header: {
				Text("Jenkins")
			} footer: {
				Text("The job that builds the GitLab project, as shown in the browser. MR builds are its MR-<number> jobs.")
					.foregroundStyle(.secondary)
			}
			Section("GitLab") {
				WideField(title: "GitLab", text: model.teamValue("gitlab_url"), prompt: "https://gitlab.example.com")
				WideField(title: "Project", text: model.teamValue("gitlab_project"), prompt: "group/subgroup/project")
			}
			Section {
				TextField("Committed label", text: model.teamValue("committed_label"), prompt: Text("Off"))
				TextField("Slot label prefix", text: model.teamValue("slot_label_prefix"), prompt: Text("Off, e.g. slot::"))
				TextField("Ignored merge requests", text: model.teamValue("ignored_merge_request_prefix"), prompt: Text("Off, a title prefix"))
			} header: {
				Text("Work item conventions")
			} footer: {
				Text("Committed work items get their own section that sorting and limits never hide. The slot label's value shows before a work item's title. Merge requests whose title starts with the prefix, like automatic cascades, don't count as work on a work item.")
					.foregroundStyle(.secondary)
			}
			Section {
				Button("Open team.conf") { model.openInEditor(model.snapshot?.files.team) }
			} footer: {
				Text("The team settings live in config/team.conf, which your team can share.")
					.foregroundStyle(.secondary)
			}
		}
	}
}
