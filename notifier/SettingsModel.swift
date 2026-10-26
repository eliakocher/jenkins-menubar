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

	let settings: [String: String]
	let team: [String: String]
	let labels: [String]
	let tokens: [String: Token]
	let files: Files
	let links: Links
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

	var labels: [String] {
		snapshot?.labels ?? []
	}

	private func labelList(_ key: String) -> [String] {
		(settings[key] ?? "").split(separator: ",").map(String.init)
	}

	var withLabels: [String] { labelList("work_items_with_labels") }
	var withoutLabels: [String] { labelList("work_items_without_labels") }

	func labelFilter(_ label: String) -> Binding<LabelFilter> {
		Binding(
			get: {
				if self.withLabels.contains(label) { return .with }
				if self.withoutLabels.contains(label) { return .without }
				return .any
			},
			set: { filter in
				self.perform(["--label-filter", label, filter.rawValue])
				self.reload()
			}
		)
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
	private func refreshMenuSoon() {
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
