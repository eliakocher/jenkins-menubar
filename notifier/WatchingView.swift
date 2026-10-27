import AppKit
import SwiftUI

/// The builds of others that the menu shows like mine: a link to paste, and the list. The menu's Watch a Build… opens
/// it, with a link copied before already in the field.
struct WatchingPane: View {
	@ObservedObject var model: SettingsModel
	@ViewState private var link = ""
	@ViewState private var watching = false
	@ViewState private var outcome: (ok: Bool, message: String)?
	@FocusState private var focused: Bool

	var body: some View {
		Form {
			Section {
				HStack {
					TextField("Link", text: $link, prompt: Text("A link to a Jenkins build or a GitLab merge request, or !123"))
						.labelsHidden()
						.focused($focused)
						.onSubmit(watch)
					if watching {
						ProgressView().controlSize(.small)
					} else {
						Button("Watch", action: watch)
							.keyboardShortcut(.defaultAction)
							.disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
					}
				}
				if let outcome {
					Label(outcome.message, systemImage: outcome.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
						.foregroundStyle(outcome.ok ? .green : .red)
				}
			} header: {
				Text("Watch a build")
			} footer: {
				Text("Watches all builds of the merge request or branch, the next ones too, until Jenkins drops its job or you stop watching. They show in the menu under Watching and follow the same rules as yours: the same alerts, the same hiding.")
					.foregroundStyle(.secondary)
			}
			Section("Watching") {
				if model.watched.isEmpty {
					Text("Nothing yet: copy a link, choose Watch a Build… in the menu and press Return.")
						.foregroundStyle(.secondary)
				}
				ForEach(model.watched) { watched in
					WatchedRow(watched: watched) { model.unwatch(watched.job) }
				}
			}
		}
		.onAppear {
			model.reload()
			pasteCopiedLink()
			focused = true
		}
		// Watch a Build… brings the window back with a newly copied link.
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
			pasteCopiedLink()
			model.reload()
		}
	}

	/// A link copied before opening the pane is most likely the one to watch.
	private func pasteCopiedLink() {
		guard !watching, let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
			copied != link, model.watched.allSatisfy({ !copied.contains("/job/\($0.job)/") }),
			copied.range(of: #"^(!|MR-)?[0-9]+$|^https?://\S+/(job/|-/merge_requests/)"#, options: .regularExpression) != nil
		else { return }
		link = copied
		outcome = nil
	}

	private func watch() {
		let text = link.trimmingCharacters(in: .whitespaces)
		guard !text.isEmpty, !watching else { return }
		watching = true
		outcome = nil
		Task {
			let result = await model.watch(text)
			watching = false
			switch result {
			case .success(let watched) where watched.mine:
				outcome = (true, "\(watched.label) is yours: the menu shows its builds anyway.")
			case .success(let watched):
				outcome = (true, "Watching all builds of \(watched.label).")
				link = ""
			case .failure(let error):
				outcome = (false, error.localizedDescription)
			}
		}
	}
}

/// A watched build or job, with what the last check found.
struct WatchedRow: View {
	let watched: Snapshot.Watched
	let stop: () -> Void

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			Group {
				if let outcome {
					OutcomePill(outcome: outcome)
				} else {
					OutcomePill(outcome: LogEntry.Outcome("neutral:WAITING")!)
						.help("Jenkins is asked at the next check")
				}
			}
			.frame(width: 92, alignment: .leading)
			VStack(alignment: .leading, spacing: 2) {
				Link(watched.build.map { "\(watched.label) #\($0)" } ?? watched.label, destination: URL(string: watched.url) ?? URL(fileURLWithPath: "/"))
					.fontWeight(.medium)
				if let title = watched.title {
					Text(title)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				if let author = watched.author {
					Text("by \(author)")
						.font(.callout)
						.foregroundStyle(.secondary)
				}
			}
			Spacer()
			Button("Stop Watching", action: stop)
		}
	}

	/// Like the pills of the log.
	private var outcome: LogEntry.Outcome? {
		if watched.building {
			return LogEntry.Outcome("running:RUNNING")
		}
		switch watched.result {
		case nil: return nil
		case "SUCCESS": return LogEntry.Outcome("ok:SUCCESS")
		case "FAILURE": return LogEntry.Outcome("failed:FAILURE")
		case "UNSTABLE": return LogEntry.Outcome("warning:UNSTABLE")
		case let result?: return LogEntry.Outcome(Substring("neutral:\(result)"))
		}
	}
}
