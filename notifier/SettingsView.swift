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
				LabelFilterRow(filter: .with, model: model)
				LabelFilterRow(filter: .without, model: model)
				ForEach(model.missingLabels, id: \.self) { label in
					HStack {
						Label("\(label) is not in GitLab any more (renamed or removed?)", systemImage: "exclamationmark.triangle.fill")
							.foregroundStyle(.orange)
						Spacer()
						Button("Remove") { model.setLabelFilter(label, .any) }
					}
				}
			} header: {
				HStack {
					Text("Work item labels")
					Spacer()
					if model.hasLabelFilters {
						Button("Clear All") { model.clearLabelFilters() }
							.buttonStyle(.link)
							.font(.callout)
					}
				}
			} footer: {
				Text("Only for the work items, the merge requests always show. With “all of these”, a work item needs every label; it has only one label per scope (the part before ::), so a new label replaces the one of its scope. With “any of these”, one of them is enough. Work items with a “none of these” label never show.")
					.foregroundStyle(.secondary)
			}
		}
	}
}

/// GitLab's scoped labels: the scope is all before the last "::", like uStatus in uStatus::Todo.
func scopeAndValue(of label: String) -> (scope: String, value: String)? {
	guard let separator = label.range(of: "::", options: .backwards) else { return nil }
	return (String(label[..<separator.lowerBound]), String(label[separator.upperBound...]))
}

/// The labels of one filter as pills, and a dashed Add Label pill for more. The must-have filter's title chooses
/// between all of its labels and any of them.
struct LabelFilterRow: View {
	let filter: LabelFilter
	@ObservedObject var model: SettingsModel
	@State private var adding = false

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if filter == .with {
				HStack(spacing: 2) {
					Text("Must have")
					Menu(model.labelsMatch == "any" ? "any of these" : "all of these") {
						Button("all of these") { model.setLabelsMatch("all") }
						Button("any of these") { model.setLabelsMatch("any") }
					}
					.menuStyle(.button)
					.buttonStyle(.borderless)
					.fixedSize()
				}
			} else {
				Text("Must have none of these")
			}
			FlowLayout(spacing: 6) {
				ForEach(model.labels(in: filter), id: \.self) { label in
					LabelPill(name: label, color: LabelColor(model.labelColor(label)), missing: model.missingLabels.contains(label)) {
						model.setLabelFilter(label, .any)
					}
				}
				Button {
					adding = true
				} label: {
					Label("Add Label", systemImage: "plus")
						.font(.callout)
						.padding(.horizontal, 8)
						.padding(.vertical, 2)
						.overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
						.contentShape(Capsule())
				}
				.buttonStyle(.plain)
				.foregroundStyle(.secondary)
				.popover(isPresented: $adding, arrowEdge: .bottom) {
					LabelPicker(filter: filter, model: model, isPresented: $adding)
				}
			}
		}
	}
}

/// A GitLab label color (#rrggbb), with black or white text on it, whichever reads better.
struct LabelColor {
	let background: Color
	let text: Color

	init?(_ hex: String?) {
		guard let hex, hex.count == 7, hex.hasPrefix("#"), let rgb = Int(hex.dropFirst(), radix: 16) else { return nil }
		let red = Double(rgb >> 16 & 0xFF) / 255, green = Double(rgb >> 8 & 0xFF) / 255, blue = Double(rgb & 0xFF) / 255
		background = Color(red: red, green: green, blue: blue)
		text = 0.299 * red + 0.587 * green + 0.114 * blue > 0.6 ? .black : .white
	}
}

/// A label the way GitLab draws it, in its color when known: a scoped label (scope::value) as a pill with the scope
/// filled in, any other label filled in completely. A label GitLab no longer has is orange; remove adds an × that takes
/// the label out of its filter.
struct LabelPill: View {
	let name: String
	var color: LabelColor?
	var missing = false
	var remove: (() -> Void)?

	var body: some View {
		let color = missing ? nil : color
		let parts = scopeAndValue(of: name)
		let tint = missing ? Color.orange : Color.secondary
		HStack(spacing: 0) {
			if let parts {
				Text(parts.scope)
					.foregroundStyle(color?.text ?? .primary)
					.padding(.horizontal, 7)
					.padding(.vertical, 2)
					.background(color?.background ?? tint.opacity(0.28))
				Text(parts.value)
					.padding(.horizontal, 7)
					.padding(.vertical, 2)
			} else {
				Text(name)
					.foregroundStyle(color?.text ?? .primary)
					.padding(.horizontal, 7)
					.padding(.vertical, 2)
			}
			if missing {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange)
					.padding(.trailing, 5)
			}
			if let remove {
				Button(action: remove) {
					Image(systemName: "xmark.circle.fill")
				}
				.buttonStyle(.plain)
				.foregroundStyle(parts == nil ? color?.text.opacity(0.75) ?? .secondary : .secondary)
				.padding(.trailing, 5)
				.help("Remove from the filter")
				.accessibilityLabel("Remove \(name)")
			}
		}
		.font(.callout)
		.background(parts == nil ? color?.background ?? tint.opacity(0.12) : tint.opacity(0.12))
		.overlay {
			if let color, parts != nil {
				Capsule().strokeBorder(color.background, lineWidth: 1.5)
			}
		}
		.clipShape(Capsule())
	}
}

/// Add Label's popover: a search over GitLab's labels and those of the work items, with the labels as pills in their
/// GitLab colors, grouped by scope. A click puts a label in the filter or takes it out again.
struct LabelPicker: View {
	let filter: LabelFilter
	@ObservedObject var model: SettingsModel
	@Binding var isPresented: Bool
	@StateObject private var search: LabelSearch
	@FocusState private var searchFocused: Bool

	init(filter: LabelFilter, model: SettingsModel, isPresented: Binding<Bool>) {
		self.filter = filter
		self.model = model
		_isPresented = isPresented
		_search = StateObject(wrappedValue: LabelSearch(plugin: model.plugin))
	}

	var body: some View {
		VStack(spacing: 0) {
			VStack(alignment: .leading, spacing: 10) {
				Text(filter == .with ? "Work items must have \(model.labelsMatch == "any" ? "any" : "all") of these" : "Work items must have none of these")
					.font(.headline)
				HStack(spacing: 6) {
					Image(systemName: "magnifyingglass")
						.foregroundStyle(.secondary)
					TextField("Search", text: $search.text, prompt: Text("Search GitLab labels"))
						.textFieldStyle(.plain)
						.focused($searchFocused)
					if search.searching {
						ProgressView()
							.controlSize(.small)
					} else if !search.text.isEmpty {
						Button {
							search.text = ""
						} label: {
							Image(systemName: "xmark.circle.fill")
						}
						.buttonStyle(.plain)
						.foregroundStyle(.secondary)
						.accessibilityLabel("Clear the search")
					}
				}
				.padding(.horizontal, 8)
				.padding(.vertical, 6)
				.background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
			}
			.padding(14)
			Divider()
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					ForEach(groups, id: \.title) { group in
						VStack(alignment: .leading, spacing: 6) {
							Text(group.title)
								.font(.caption.weight(.semibold))
								.foregroundStyle(.secondary)
							FlowLayout(spacing: 6) {
								ForEach(group.labels, id: \.self) { label in
									choice(label, shown: group.scope == nil ? label : scopeAndValue(of: label)?.value ?? label)
								}
							}
						}
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(14)
			}
			.overlay {
				if groups.isEmpty && !search.searching {
					if search.text.isEmpty {
						ContentUnavailableView("Find a Label", systemImage: "tag",
							description: Text("Type a part of its name to search GitLab."))
					} else {
						ContentUnavailableView.search(text: search.text)
					}
				}
			}
			Divider()
			HStack {
				if let problem = search.problem {
					Label(problem, systemImage: "exclamationmark.triangle")
						.foregroundStyle(.orange)
				} else {
					Text("Click a label to add it, again to remove it.")
						.foregroundStyle(.secondary)
				}
				Spacer()
				Button("Done") { isPresented = false }
					.keyboardShortcut(.defaultAction)
			}
			.font(.callout)
			.padding(10)
		}
		.frame(width: 400, height: 460)
		.onAppear { searchFocused = true }
	}

	private func choice(_ label: String, shown: String) -> some View {
		let other: LabelFilter = filter == .with ? .without : .with
		return LabelChoice(
			text: shown,
			color: LabelColor(search.colors[label]),
			selected: model.labels(in: filter).contains(label),
			inOtherFilter: model.labels(in: other).contains(label)
		) {
			model.toggleLabel(label, in: filter)
		}
	}

	/// The scopes in alphabetical order, then the labels without one.
	private var groups: [(title: String, scope: String?, labels: [String])] {
		let byScope = Dictionary(grouping: search.labels) { scopeAndValue(of: $0)?.scope }
		let scopes = byScope.keys.compactMap { $0 }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
		return scopes.map { (title: $0, scope: $0, labels: byScope[$0] ?? []) }
			+ (byScope[nil].map { [(title: "Other labels", scope: nil, labels: $0)] } ?? [])
	}
}

/// A label in the picker, in its GitLab color: tinted until it is in the filter, then filled in with a checkmark. A label
/// in the other filter is faded; a click moves it over.
struct LabelChoice: View {
	let text: String
	let color: LabelColor?
	let selected: Bool
	let inOtherFilter: Bool
	let action: () -> Void
	@State private var hovering = false

	var body: some View {
		let tint = color?.background ?? Color.secondary
		Button(action: action) {
			HStack(spacing: 4) {
				if selected {
					Image(systemName: "checkmark")
						.font(.caption.weight(.bold))
				}
				Text(text)
			}
			.font(.callout)
			.foregroundStyle(selected ? color?.text ?? .primary : .primary)
			.padding(.horizontal, 9)
			.padding(.vertical, 3)
			.background(selected ? tint : tint.opacity(hovering ? 0.32 : 0.16), in: Capsule())
			.overlay(Capsule().strokeBorder(tint.opacity(selected ? 0 : 0.55)))
			.opacity(inOtherFilter ? 0.45 : 1)
			.contentShape(Capsule())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.help(inOtherFilter ? "In the other filter: click to move it here" : selected ? "Click to remove it" : "Click to add it")
	}
}

/// Lays its views out in rows, like words in a line of text, each centered in its row.
struct FlowLayout: Layout {
	var spacing: CGFloat = 8

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let frames = frames(width: proposal.width ?? .infinity, subviews: subviews)
		return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
			subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
		}
	}

	private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
		var frames: [CGRect] = []
		var row: [CGRect] = []
		var top: CGFloat = 0
		func endRow() {
			let height = row.map(\.height).max() ?? 0
			frames += row.map { $0.offsetBy(dx: 0, dy: (height - $0.height) / 2) }
			top += height + spacing
			row = []
		}
		for subview in subviews {
			let size = subview.sizeThatFits(.unspecified)
			if let last = row.last, last.maxX + spacing + size.width > width {
				endRow()
			}
			row.append(CGRect(origin: CGPoint(x: row.last.map { $0.maxX + spacing } ?? 0, y: top), size: size))
		}
		endRow()
		return frames
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
