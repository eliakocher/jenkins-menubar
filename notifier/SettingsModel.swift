import AppKit
import SwiftUI

/// What the plugin answers to --settings-json.
struct Snapshot: Decodable {
	struct Token: Decodable {
		/// environment, keychain, zshrc, zshrc-computed or none
		let source: String
		let user: String
	}

	struct Files: Decodable {
		let settings: String
		let team: String
	}

	struct Links: Decodable {
		let jenkinsToken: String?
		let gitlabToken: String?
	}

	/// The log, with its older files next to it as .1, .2, …, the check times and the requests with their responses.
	struct Logs: Decodable {
		let file: String
		let checks: String
		let requests: String
		/// the most all of them take together
		let maxBytes: Int64
	}

	/// A job of someone else, whose builds the menu shows like mine.
	struct Watched: Decodable, Identifiable {
		let job: String
		/// like !123, or develop for a branch
		let label: String
		/// what the last check found
		let build: Int?
		let building: Bool
		let result: String?
		let title: String?
		let author: String?
		let url: String

		var id: String { job }
	}

	let settings: [String: String]
	let team: [String: String]
	/// the filter labels GitLab no longer has
	let missingLabels: [String]
	/// GitLab's colors of the filter labels, like #9400d3
	let labelColors: [String: String]
	let tokens: [String: Token]
	let watched: [Watched]?
	let files: Files
	let logs: Logs?
	let links: Links
}

/// What the plugin answers to --watch.
struct WatchResult: Decodable {
	let job: String
	let label: String
	let title: String
	/// a job of mine, which the menu shows anyway
	let mine: Bool
}

/// What the plugin answers to --check-accounts.
struct AccountCheck: Decodable {
	struct Result: Decodable {
		let ok: Bool
		let message: String
	}

	let jenkins: Result
	let gitlab: Result
}

/// What the plugin answers to --search-labels.
struct LabelSearchResult: Decodable {
	let labels: [String]
	/// GitLab's colors of the labels it knows
	let colors: [String: String]
	/// why GitLab's labels are missing
	let problem: String?
}

struct PluginError: LocalizedError {
	let errorDescription: String?
}

/// The SwiftBar plugin owns the settings and their logic (and its tests cover them): the window only shows what the
/// plugin answers and asks it for every change.
struct Plugin: Sendable {
	let script: URL

	@discardableResult
	func run(_ arguments: [String], input: String? = nil) throws -> Data {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/bash")
		process.arguments = [script.path] + arguments
		let output = Pipe()
		let errors = Pipe()
		let stdin = Pipe()
		process.standardOutput = output
		process.standardError = errors
		process.standardInput = input == nil ? FileHandle.nullDevice : stdin
		try process.run()
		if let input {
			stdin.fileHandleForWriting.write(Data(input.utf8))
			try stdin.fileHandleForWriting.close()
		}
		let data = output.fileHandleForReading.readDataToEndOfFile()
		let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
		process.waitUntilExit()
		guard process.terminationStatus == 0 else {
			let reason = message.trimmingCharacters(in: .whitespacesAndNewlines)
			throw PluginError(errorDescription: reason.isEmpty ? "The plugin failed (exit status \(process.terminationStatus))" : reason)
		}
		return data
	}
}

enum LabelFilter: String, CaseIterable {
	case any, with, without
}

@MainActor
final class SettingsModel: ObservableObject {
	@Published private(set) var snapshot: Snapshot?
	@Published private(set) var settings: [String: String] = [:]
	@Published private(set) var team: [String: String] = [:]
	@Published var problem: String?
	@Published private(set) var accountCheck: AccountCheck?
	@Published private(set) var checkingAccounts = false

	let plugin: Plugin
	private var teamSaves: [String: Task<Void, Never>] = [:]
	private var menuRefresh: Task<Void, Never>?

	init(plugin: Plugin) {
		self.plugin = plugin
		reload()
	}

	func reload() {
		do {
			let snapshot = try JSONDecoder().decode(Snapshot.self, from: plugin.run(["--settings-json"]))
			self.snapshot = snapshot
			settings = snapshot.settings
			team = snapshot.team
		} catch {
			problem = error.localizedDescription
		}
	}

	// ── Settings ──

	func setting(_ key: String) -> Binding<String> {
		Binding(
			get: { self.settings[key] ?? "" },
			set: { value in
				self.settings[key] = value
				self.perform(["--set", key, value])
			}
		)
	}

	/// An on | off setting.
	func flag(_ key: String) -> Binding<Bool> {
		Binding(
			get: { self.settings[key] == "on" },
			set: { self.setting(key).wrappedValue = $0 ? "on" : "off" }
		)
	}

	/// A team.conf value, saved once typing pauses.
	func teamValue(_ key: String) -> Binding<String> {
		Binding(
			get: { self.team[key] ?? "" },
			set: { value in
				self.team[key] = value
				self.teamSaves[key]?.cancel()
				self.teamSaves[key] = Task {
					try? await Task.sleep(for: .milliseconds(600))
					guard !Task.isCancelled else { return }
					self.perform(["--set-team", key, value.trimmingCharacters(in: .whitespaces)])
					self.reload()
				}
			}
		)
	}

	// ── Label filters ──

	/// The labels a work item must have (with) or must not have (without).
	func labels(in filter: LabelFilter) -> [String] {
		filter == .any ? [] : (settings["work_items_\(filter.rawValue)_labels"] ?? "").split(separator: ",").map(String.init)
	}

	var hasLabelFilters: Bool {
		!(labels(in: .with) + labels(in: .without)).isEmpty
	}

	var missingLabels: [String] {
		snapshot?.missingLabels ?? []
	}

	func labelColor(_ label: String) -> String? {
		snapshot?.labelColors[label]
	}

	/// Puts the label in the filter, out of the other one; the plugin keeps one must-have label per scope.
	func setLabelFilter(_ label: String, _ filter: LabelFilter) {
		perform(["--label-filter", label, filter.rawValue])
		reload()
	}

	/// Whether a work item needs all must-have labels or any one of them: all | any.
	var labelsMatch: String {
		settings["work_items_labels_match"] ?? "all"
	}

	/// For all, the plugin keeps the last must-have label of each scope.
	func setLabelsMatch(_ match: String) {
		perform(["--label-match", match])
		reload()
	}

	/// Adds the label to the filter, or takes it out when it is in already.
	func toggleLabel(_ label: String, in filter: LabelFilter) {
		setLabelFilter(label, labels(in: filter).contains(label) ? .any : filter)
	}

	func clearLabelFilters() {
		perform(["--clear-labels"])
		reload()
	}

	// ── Tokens ──

	func token(_ name: String) -> Snapshot.Token? {
		snapshot?.tokens[name]
	}

	func saveJenkinsToken(user: String, token: String) -> Bool {
		let auth = Data("\(user.trimmingCharacters(in: .whitespaces)):\(token.trimmingCharacters(in: .whitespaces))".utf8)
		return saveToken("JENKINS_MCP_BASIC_AUTH", auth.base64EncodedString())
	}

	func saveGitLabToken(_ token: String) -> Bool {
		saveToken("GITLAB_TOKEN", token.trimmingCharacters(in: .whitespaces))
	}

	/// The plugin gets the token on stdin, never as an argument, so it does not show up in ps.
	private func saveToken(_ name: String, _ value: String) -> Bool {
		let saved = perform(["--set-token", name], input: value)
		reload()
		accountCheck = nil
		return saved
	}

	func deleteToken(_ name: String) {
		perform(["--delete-token", name])
		reload()
		accountCheck = nil
	}

	func checkAccounts() {
		checkingAccounts = true
		let plugin = plugin
		Task {
			let result = await Task.detached { () -> Result<AccountCheck, Error> in
				Result { try JSONDecoder().decode(AccountCheck.self, from: plugin.run(["--check-accounts"])) }
			}.value
			checkingAccounts = false
			switch result {
			case .success(let check): accountCheck = check
			case .failure(let error): problem = error.localizedDescription
			}
		}
	}

	// ── Actions ──

	/// Shows the alert of a finished build the way the settings make it look; the dialog waits for a click, so the
	/// plugin runs in the background.
	func previewAlert(success: Bool) {
		let plugin = plugin
		Task.detached {
			_ = try? plugin.run([success ? "--preview-success" : "--preview-failure"])
		}
	}

	// ── Watching ──

	var watched: [Snapshot.Watched] {
		snapshot?.watched ?? []
	}

	/// Watches the job of what was pasted; the plugin asks Jenkins first, so it runs in the background.
	func watch(_ text: String) async -> Result<WatchResult, Error> {
		let plugin = plugin
		let result = await Task.detached {
			Result { try JSONDecoder().decode(WatchResult.self, from: plugin.run(["--watch", text])) }
		}.value
		if case .success(let watched) = result, !watched.mine {
			reload()
			refreshMenuSoon()
		}
		return result
	}

	func unwatch(_ job: String) {
		perform(["--unwatch", job])
		reload()
	}

	// ── Logs ──

	/// The Logs pane notices on its own that the files are gone.
	func clearLogs() {
		perform(["--clear-logs"])
	}

	/// Opens the file in the default text editor, like the menu does.
	func openInEditor(_ path: String?) {
		guard let path else { return }
		_ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-t", path])
	}

	@discardableResult
	private func perform(_ arguments: [String], input: String? = nil) -> Bool {
		do {
			try plugin.run(arguments, input: input)
			problem = nil
			refreshMenuSoon()
			return true
		} catch {
			problem = error.localizedDescription
			return false
		}
	}

	/// SwiftBar renders the menu again after a short pause, so several quick changes refresh it once.
	/// It also asks GitLab again, which checks that the filter labels still exist.
	func refreshMenuSoon() {
		menuRefresh?.cancel()
		menuRefresh = Task {
			try? await Task.sleep(for: .milliseconds(700))
			guard !Task.isCancelled, let url = URL(string: "swiftbar://refreshallplugins") else { return }
			let configuration = NSWorkspace.OpenConfiguration()
			configuration.activates = false
			NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
		}
	}
}

/// The search of the label filters' Add…: the plugin asks GitLab, so it runs in the background, once typing pauses.
@MainActor
final class LabelSearch: ObservableObject {
	@Published var text = "" {
		didSet { start(after: .milliseconds(300)) }
	}
	@Published private(set) var labels: [String] = []
	@Published private(set) var colors: [String: String] = [:]
	@Published private(set) var searching = false
	@Published private(set) var problem: String?

	private let plugin: Plugin
	private var search: Task<Void, Never>?

	init(plugin: Plugin) {
		self.plugin = plugin
		start(after: .zero)
	}

	private func start(after pause: Duration) {
		search?.cancel()
		let plugin = plugin
		let text = text.trimmingCharacters(in: .whitespaces)
		search = Task {
			try? await Task.sleep(for: pause)
			guard !Task.isCancelled else { return }
			searching = true
			let result = await Task.detached { () -> Result<LabelSearchResult, Error> in
				Result { try JSONDecoder().decode(LabelSearchResult.self, from: plugin.run(["--search-labels", text])) }
			}.value
			guard !Task.isCancelled else { return }
			searching = false
			switch result {
			case .success(let found):
				labels = found.labels
				colors = found.colors
				problem = found.problem
			case .failure(let error):
				problem = error.localizedDescription
			}
		}
	}
}
