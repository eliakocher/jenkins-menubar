import AppKit
import Charts
import SwiftUI

/// A line of the log that the plugin and jenkins-watch write, see log in plugins/jenkins.30s.sh.
struct LogEntry: Identifiable, Sendable {
	enum Level: String, Sendable {
		case debug, info, warning, error
	}

	/// How something went, like ok:200 or failed:TIMEOUT in the log.
	struct Outcome: Sendable {
		enum Kind: String, Sendable {
			case ok, failed, warning, running, neutral
		}

		let kind: Kind
		let label: String

		init?(_ text: Substring) {
			guard let colon = text.firstIndex(of: ":"), let kind = Kind(rawValue: String(text[..<colon])) else { return nil }
			self.kind = kind
			label = String(text[text.index(after: colon)...])
		}

		var color: Color {
			switch kind {
			case .ok: .green
			case .failed: .red
			case .warning: .orange
			case .running: .blue
			case .neutral: .gray
			}
		}

		var symbol: String {
			switch kind {
			case .ok: "checkmark"
			case .failed: "xmark"
			case .warning: "exclamationmark"
			case .running: "play.fill"
			case .neutral: "minus"
			}
		}
	}

	let id: Int
	let date: Date
	let level: Level
	let source: String
	let message: String
	let detail: String
	let outcome: Outcome?
	/// The file with the request and its response, for a request to Jenkins or GitLab.
	let request: String
	/// The message, detail and source in lowercase, so searching thousands of entries stays quick.
	let searchText: String

	var time: String {
		date.formatted(Date.ISO8601FormatStyle(dateTimeSeparator: .space, timeZone: .current).year().month().day().time(includingFractionalSeconds: false))
	}

	/// The entry as a line of text, for the clipboard.
	var text: String {
		[time, level.rawValue.uppercased(), LogSource.name(source), outcome?.label ?? "", message, detail].filter { !$0.isEmpty }.joined(separator: "  ")
	}
}

/// The checks of Jenkins or GitLab in one hour: the time their requests took together, on average.
struct HourOfChecks: Identifiable, Sendable {
	let hour: Date
	let source: String
	let seconds: Double
	let failedRequests: Int

	var id: String { "\(source) \(hour.timeIntervalSince1970)" }
}

/// Where a log entry comes from, the way the Logs pane shows it.
enum LogSource {
	static let all = ["jenkins", "gitlab", "alerts", "settings", "menu"]

	static func name(_ source: String) -> String {
		switch source {
		case "jenkins": "Jenkins"
		case "gitlab": "GitLab"
		case "alerts": "Alerts"
		case "settings": "Settings"
		case "menu": "Menu"
		default: source.capitalized
		}
	}

	static func symbol(_ source: String) -> String {
		switch source {
		case "jenkins": "hammer.fill"
		case "gitlab": "arrow.triangle.merge"
		case "alerts": "bell.fill"
		case "settings": "gearshape.fill"
		default: "menubar.rectangle"
		}
	}

	/// Jenkins and GitLab like their panes.
	static func color(_ source: String) -> Color {
		switch source {
		case "jenkins": .blue
		case "gitlab": .orange
		case "alerts": .pink
		case "settings": .gray
		default: .purple
		}
	}
}

/// What the Logs pane shows: the log files (the log and its older .1, .2, … files) and the check times, read again
/// whenever one of them changes.
@MainActor
final class LogStore: ObservableObject {
	struct Contents: Sendable {
		/// newest first
		var entries: [LogEntry] = []
		/// the last 24 hours
		var hours: [HourOfChecks] = []
		/// the seconds a check took on average in the last 24 hours, by source
		var averages: [String: Double] = [:]
		var failedRequests: [String: Int] = [:]
		/// what the log files and the check times take on disk
		var bytes: Int64 = 0
	}

	@Published private(set) var contents = Contents()
	@Published private(set) var loaded = false

	let logFile: URL
	let checksFile: URL
	let requests: URL
	private var signature = ""
	private var generation = 0
	private var timer: Timer?

	init(logFile: String, checksFile: String, requests: String) {
		self.logFile = URL(fileURLWithPath: logFile)
		self.checksFile = URL(fileURLWithPath: checksFile)
		self.requests = URL(fileURLWithPath: requests)
	}

	/// The request and response kept for the entry, or nil once the plugin made room for newer ones.
	func request(of entry: LogEntry) -> RequestRecord? {
		guard !entry.request.isEmpty, !entry.request.contains("/"),
			let data = FileManager.default.contents(atPath: requests.appendingPathComponent(entry.request).path)
		else { return nil }
		return try? JSONDecoder().decode(RequestRecord.self, from: data)
	}

	/// Follows the files while the pane shows.
	func start() {
		reloadIfChanged()
		timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.reloadIfChanged() }
		}
	}

	func stop() {
		timer?.invalidate()
		timer = nil
	}

	private func reloadIfChanged() {
		let signature = (Self.logFiles(of: logFile) + [checksFile]).map { file in
			let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
			let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
			return "\(file.lastPathComponent) \(attributes?[.size] as? Int64 ?? -1) \(modified)"
		}.joined(separator: "|")
		guard signature != self.signature else { return }
		self.signature = signature
		generation += 1
		let generation = generation, logFile = logFile, checksFile = checksFile, requests = requests
		Task {
			let contents = await Task.detached { Self.read(logFile: logFile, checksFile: checksFile, requests: requests) }.value
			// A read that started later may have finished first.
			guard generation == self.generation else { return }
			self.contents = contents
			loaded = true
		}
	}

	/// The log files, oldest first: the plugin moves a full log to .1 and the older ones up a number.
	nonisolated static func logFiles(of log: URL) -> [URL] {
		let directory = log.deletingLastPathComponent()
		let name = log.lastPathComponent
		let older = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
			.compactMap { file -> (number: Int, url: URL)? in
				guard file.hasPrefix(name + "."), let number = Int(file.dropFirst(name.count + 1)) else { return nil }
				return (number, directory.appendingPathComponent(file))
			}
			.sorted { $0.number > $1.number }
			.map(\.url)
		return older + (FileManager.default.fileExists(atPath: log.path) ? [log] : [])
	}

	nonisolated static func read(logFile: URL, checksFile: URL, requests: URL) -> Contents {
		var contents = Contents()
		var entries: [LogEntry] = []
		for file in logFiles(of: logFile) {
			guard let data = FileManager.default.contents(atPath: file.path) else { continue }
			contents.bytes += Int64(data.count)
			// The time, level, source, message, detail, outcome and request file; lines from before have no outcome or request.
			for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
				let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
				guard fields.count >= 4, let date = parseDate(fields[0]) else { continue }
				let detail = fields.count > 4 ? String(fields[4]) : ""
				let outcome = fields.count > 5 ? LogEntry.Outcome(fields[5]) : nil
				entries.append(LogEntry(
					id: entries.count, date: date, level: LogEntry.Level(rawValue: String(fields[1])) ?? .info,
					source: String(fields[2]), message: String(fields[3]), detail: detail, outcome: outcome,
					request: fields.count > 6 ? String(fields[6]) : "",
					searchText: "\(fields[3]) \(detail) \(LogSource.name(String(fields[2]))) \(outcome?.label ?? "")".lowercased()
				))
			}
		}
		contents.entries = entries.reversed()
		for file in (try? FileManager.default.contentsOfDirectory(atPath: requests.path)) ?? [] {
			let attributes = try? FileManager.default.attributesOfItem(atPath: requests.appendingPathComponent(file).path)
			contents.bytes += attributes?[.size] as? Int64 ?? 0
		}

		// Each line: the time, jenkins or gitlab, the seconds of the check's requests together, how many there were and how
		// many failed.
		guard let data = FileManager.default.contents(atPath: checksFile.path) else { return contents }
		contents.bytes += Int64(data.count)
		let since = Date().timeIntervalSince1970 - 86400
		var hours: [String: (hour: Date, source: String, seconds: Double, checks: Int, failed: Int)] = [:]
		for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
			let fields = line.split(separator: "\t")
			guard fields.count >= 5, let time = Double(fields[0]), time >= since, let seconds = Double(fields[2]),
				let failed = Int(fields[4]) else { continue }
			let source = String(fields[1])
			let hour = Date(timeIntervalSince1970: (time / 3600).rounded(.down) * 3600)
			let key = "\(source) \(hour.timeIntervalSince1970)"
			let sum = hours[key] ?? (hour, source, 0, 0, 0)
			hours[key] = (hour, source, sum.seconds + seconds, sum.checks + 1, sum.failed + failed)
		}
		contents.hours = hours.values
			.map { HourOfChecks(hour: $0.hour, source: $0.source, seconds: $0.seconds / Double($0.checks), failedRequests: $0.failed) }
			.sorted { $0.hour < $1.hour }
		for source in Set(hours.values.map(\.source)) {
			let checks = hours.values.filter { $0.source == source }
			contents.averages[source] = checks.map(\.seconds).reduce(0, +) / Double(checks.map(\.checks).reduce(0, +))
			contents.failedRequests[source] = checks.map(\.failed).reduce(0, +)
		}
		return contents
	}

	/// Reads the time of a log line, like 2026-10-27T08:35:12+0100, without a DateFormatter, which takes long for the
	/// tens of thousands of lines of the logs.
	nonisolated static func parseDate(_ text: Substring) -> Date? {
		let characters = Array(text.utf8)
		guard characters.count == 24 else { return nil }
		func number(_ range: Range<Int>) -> Int? {
			var value = 0
			for index in range {
				let digit = Int(characters[index]) - 48
				guard (0 ... 9).contains(digit) else { return nil }
				value = value * 10 + digit
			}
			return value
		}
		guard let year = number(0 ..< 4), let month = number(5 ..< 7), let day = number(8 ..< 10), let hour = number(11 ..< 13),
			let minute = number(14 ..< 16), let second = number(17 ..< 19), let offsetHours = number(20 ..< 22),
			let offsetMinutes = number(22 ..< 24)
		else { return nil }
		// The days since 1970-01-01 (days_from_civil, by Howard Hinnant), for years after 0.
		let shiftedYear = month <= 2 ? year - 1 : year
		let era = shiftedYear / 400
		let yearOfEra = shiftedYear - era * 400
		let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
		let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
		let days = era * 146_097 + dayOfEra - 719_468
		let offset = (offsetHours * 3600 + offsetMinutes * 60) * (characters[19] == UInt8(ascii: "-") ? -1 : 1)
		return Date(timeIntervalSince1970: TimeInterval(days * 86400 + hour * 3600 + minute * 60 + second - offset))
	}
}

/// Which levels the Logs show.
enum LevelFilter: String, CaseIterable {
	case everything, events, problems

	var title: String {
		switch self {
		case .everything: "Everything"
		case .events: "Events"
		case .problems: "Problems"
		}
	}

	func includes(_ level: LogEntry.Level) -> Bool {
		switch self {
		case .everything: true
		case .events: level != .debug
		case .problems: level == .warning || level == .error
		}
	}
}

struct LogsPane: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		if let logs = model.snapshot?.logs {
			LogsView(model: model, logs: logs)
		} else {
			ContentUnavailableView("No Logs", systemImage: "doc.text.magnifyingglass", description: Text("The plugin did not say where its logs are."))
		}
	}
}

/// The entries of the logs, newest first and by day, with the check times above them.
struct LogsView: View {
	@ObservedObject var model: SettingsModel
	let logs: Snapshot.Logs
	@StateObject private var store: LogStore
	@AppStorage("logs.level") private var level = LevelFilter.everything
	@AppStorage("logs.source") private var source = ""
	@ViewState private var search = ""
	@ViewState private var selection = Set<Int>()
	@ViewState private var confirmingClear = false
	@ViewState private var inspected: LogEntry?

	/// More rows make the list slow; searching and the filters reach the older ones.
	private static let shownAtMost = 1000

	init(model: SettingsModel, logs: Snapshot.Logs) {
		self.model = model
		self.logs = logs
		_store = StateObject(wrappedValue: LogStore(logFile: logs.file, checksFile: logs.checks, requests: logs.requests))
	}

	var body: some View {
		let matching = matchingEntries
		VStack(spacing: 0) {
			CheckTimesView(contents: store.contents)
				.padding(.horizontal, 20)
				.padding(.vertical, 12)
			Divider()
			filterBar(count: matching.count)
			Divider()
			entries(matching)
		}
		.safeAreaInset(edge: .bottom, spacing: 0) {
			footer
		}
		.searchable(text: $search, placement: .toolbar, prompt: "Search the logs")
		.toolbar {
			ToolbarItemGroup {
				Button("Copy", systemImage: "doc.on.doc") { copy(matching) }
					.help("Copy the entries shown")
					.disabled(matching.isEmpty)
				Button("Show in Finder", systemImage: "folder") { showInFinder() }
					.help("Show the log files in the Finder")
				Button("Clear Logs", systemImage: "trash") { confirmingClear = true }
					.help("Delete the logs, the check times and the requests")
					.disabled(store.contents.entries.isEmpty && store.contents.hours.isEmpty)
			}
		}
		.confirmationDialog("Clear the logs?", isPresented: $confirmingClear) {
			Button("Clear Logs", role: .destructive) { model.clearLogs() }
		} message: {
			Text("This deletes the log, the check times and the requests with their responses. They start again with the next check.")
		}
		.sheet(item: $inspected) { entry in
			EntryDetails(entry: entry, request: store.request(of: entry))
		}
		.onAppear { store.start() }
		.onDisappear { store.stop() }
	}

	private var matchingEntries: [LogEntry] {
		let words = search.trimmingCharacters(in: .whitespaces).lowercased()
		return store.contents.entries.filter { entry in
			level.includes(entry.level) && (source.isEmpty || entry.source == source) && (words.isEmpty || entry.searchText.contains(words))
		}
	}

	private func filterBar(count: Int) -> some View {
		HStack(spacing: 12) {
			Picker("Show", selection: $level) {
				ForEach(LevelFilter.allCases, id: \.self) { Text($0.title).tag($0) }
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			.fixedSize()
			.help("Everything: also each request and check. Events: builds, alerts, changes and problems. Problems: warnings and errors.")
			Picker("Source", selection: $source) {
				Text("All Sources").tag("")
				Divider()
				ForEach(LogSource.all, id: \.self) { source in
					Label(LogSource.name(source), systemImage: LogSource.symbol(source)).tag(source)
				}
			}
			.labelsHidden()
			.fixedSize()
			Spacer()
			Text(count == 1 ? "1 entry" : "\(count) entries")
				.monospacedDigit()
				.foregroundStyle(.secondary)
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 8)
	}

	@ViewBuilder
	private func entries(_ matching: [LogEntry]) -> some View {
		if !store.loaded {
			ProgressView()
				.frame(maxWidth: .infinity, maxHeight: .infinity)
		} else if store.contents.entries.isEmpty {
			ContentUnavailableView(
				"No Logs Yet", systemImage: "doc.text.magnifyingglass",
				description: Text("The menu writes here as soon as it checks Jenkins and GitLab.")
			)
		} else if matching.isEmpty {
			if search.isEmpty {
				ContentUnavailableView("Nothing to Show", systemImage: "line.3.horizontal.decrease.circle", description: Text("No entries pass the filters."))
			} else {
				ContentUnavailableView.search(text: search)
			}
		} else {
			let shown = Array(matching.prefix(Self.shownAtMost))
			List(selection: $selection) {
				ForEach(days(of: shown), id: \.day) { day in
					Section(dayTitle(day.day)) {
						ForEach(day.entries) { entry in
							LogRow(entry: entry) { inspected = entry }
								.listRowBackground(rowTint(entry.level))
						}
					}
				}
				if matching.count > shown.count {
					Text("The newest \(shown.count) of \(matching.count) entries: search or filter to see the older ones.")
						.font(.callout)
						.foregroundStyle(.secondary)
						.selectionDisabled()
				}
			}
			.listStyle(.inset)
			// A double-click or Return shows the details of the entry.
			.contextMenu(forSelectionType: Int.self) { ids in
				Button("Show Details") { inspected = shown.first { ids.first == $0.id } }
					.disabled(ids.count != 1)
				Button("Copy") { copy(shown.filter { ids.contains($0.id) }) }
			} primaryAction: { ids in
				inspected = shown.first { ids.first == $0.id }
			}
			.onCopyCommand {
				let selected = shown.filter { selection.contains($0.id) }
				return [NSItemProvider(object: text(of: selected) as NSString)]
			}
		}
	}

	private var footer: some View {
		HStack(spacing: 6) {
			Image(systemName: "internaldrive")
			if let oldest = store.contents.entries.last?.date {
				Text("Since \(oldest.formatted(.dateTime.weekday().day().month().hour().minute())) ·")
			}
			Text("\(store.contents.bytes.formatted(.byteCount(style: .file))) of at most \(logs.maxBytes.formatted(.byteCount(style: .file))): the oldest entries go first")
			Spacer()
		}
		.font(.callout)
		.foregroundStyle(.secondary)
		.padding(.horizontal, 20)
		.padding(.vertical, 8)
		.background(.bar)
	}

	private func days(of entries: [LogEntry]) -> [(day: Date, entries: [LogEntry])] {
		var days: [(day: Date, entries: [LogEntry])] = []
		for entry in entries {
			let day = Calendar.current.startOfDay(for: entry.date)
			if days.last?.day == day {
				days[days.count - 1].entries.append(entry)
			} else {
				days.append((day, [entry]))
			}
		}
		return days
	}

	private func dayTitle(_ day: Date) -> String {
		if Calendar.current.isDateInToday(day) { return "Today" }
		if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
		return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
	}

	private func rowTint(_ level: LogEntry.Level) -> Color? {
		switch level {
		case .error: .red.opacity(0.08)
		case .warning: .orange.opacity(0.06)
		default: nil
		}
	}

	/// The entries in the order they happened.
	private func text(of entries: [LogEntry]) -> String {
		entries.reversed().map(\.text).joined(separator: "\n")
	}

	private func copy(_ entries: [LogEntry]) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text(of: entries), forType: .string)
	}

	private func showInFinder() {
		if FileManager.default.fileExists(atPath: store.logFile.path) {
			NSWorkspace.shared.activateFileViewerSelecting([store.logFile])
		} else {
			NSWorkspace.shared.open(store.logFile.deletingLastPathComponent())
		}
	}
}

struct LogRow: View {
	let entry: LogEntry
	let showDetails: () -> Void

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			Text(entry.date, format: .dateTime.hour().minute().second())
				.monospacedDigit()
				.foregroundStyle(.secondary)
			// How it went, or else how bad it is.
			Group {
				if let outcome = entry.outcome {
					OutcomePill(outcome: outcome)
				} else {
					LevelIcon(level: entry.level)
				}
			}
			.frame(width: 92, alignment: .leading)
			SourceTag(source: entry.source)
			VStack(alignment: .leading, spacing: 2) {
				Text(entry.message)
					.foregroundStyle(entry.level == .debug ? .secondary : .primary)
				if !entry.detail.isEmpty {
					Text(entry.detail)
						.font(.callout)
						.foregroundStyle(.secondary)
						.lineLimit(2)
				}
			}
			.help(entry.detail.isEmpty ? entry.message : "\(entry.message)\n\(entry.detail)")
			Spacer(minLength: 0)
			if !entry.request.isEmpty {
				Button("Request and Response", systemImage: "info.circle", action: showDetails)
					.labelStyle(.iconOnly)
					.buttonStyle(.borderless)
					.foregroundStyle(.secondary)
					.help("Show the request and the response")
			}
		}
		.padding(.vertical, 2)
	}
}

/// How something went, like a 200 or a timeout of a request, or the result of a build: a small pill in its color.
struct OutcomePill: View {
	let outcome: LogEntry.Outcome

	var body: some View {
		HStack(spacing: 3) {
			Image(systemName: outcome.symbol)
				.font(.system(size: 8, weight: .heavy))
			Text(outcome.label)
				.lineLimit(1)
		}
		.font(.caption.weight(.semibold))
		.foregroundStyle(outcome.color)
		.padding(.horizontal, 7)
		.padding(.vertical, 2)
		.background(Capsule().fill(outcome.color.opacity(0.16)))
	}
}

struct LevelIcon: View {
	let level: LogEntry.Level

	var body: some View {
		Group {
			switch level {
			case .debug: Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.tertiary)
			case .info: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
			case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
			case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
			}
		}
		.frame(width: 16)
		.help(level.rawValue.capitalized)
	}
}

/// The source of an entry as a small tag in its color.
struct SourceTag: View {
	let source: String

	var body: some View {
		Text(LogSource.name(source))
			.font(.caption.weight(.medium))
			.foregroundStyle(LogSource.color(source))
			.padding(.horizontal, 6)
			.padding(.vertical, 1)
			.background(Capsule().fill(LogSource.color(source).opacity(0.14)))
			.frame(width: 64, alignment: .leading)
	}
}

/// How long the checks of Jenkins and GitLab took in the last 24 hours (their requests together), with the hour under
/// the pointer.
struct CheckTimesView: View {
	let contents: LogStore.Contents
	@AppStorage("logs.showsCheckTimes") private var showsChart = true
	@ViewState private var pointed: Date?

	private static let sources = ["jenkins", "gitlab"]

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .firstTextBaseline, spacing: 16) {
				Button {
					withAnimation(.snappy) { showsChart.toggle() }
				} label: {
					HStack(spacing: 6) {
						Image(systemName: "chevron.right")
							.font(.caption.weight(.semibold))
							.rotationEffect(.degrees(showsChart ? 90 : 0))
						Text("Check Times").font(.headline)
					}
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.help("The time the requests of a check of Jenkins or GitLab took together")
				Text(pointedHour.map { "\($0.formatted(.dateTime.hour().minute()))–\($0.addingTimeInterval(3600).formatted(.dateTime.hour().minute()))" } ?? "last 24 hours")
					.foregroundStyle(.secondary)
					.monospacedDigit()
				Spacer()
				ForEach(Self.sources, id: \.self) { source in
					average(source)
				}
			}
			if showsChart {
				if contents.hours.isEmpty {
					Text("No checks in the last 24 hours yet.")
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, minHeight: 110)
				} else {
					chart.frame(height: 110)
				}
			}
		}
	}

	private var pointedHour: Date? {
		pointed.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 3600).rounded(.down) * 3600) }
	}

	/// The average of the last 24 hours, or of the hour under the pointer.
	private func average(_ source: String) -> some View {
		let hour = pointedHour.flatMap { hour in contents.hours.first { $0.hour == hour && $0.source == source } }
		let seconds = pointedHour == nil ? contents.averages[source] : hour?.seconds
		let failed = pointedHour == nil ? contents.failedRequests[source] ?? 0 : hour?.failedRequests ?? 0
		return HStack(spacing: 5) {
			Circle().fill(LogSource.color(source)).frame(width: 8, height: 8)
			Text(LogSource.name(source))
			Text(seconds.map { "avg \(Self.duration($0))" } ?? "–")
				.monospacedDigit()
				.foregroundStyle(.secondary)
			if failed > 0 {
				Text(failed == 1 ? "1 failed" : "\(failed) failed")
					.foregroundStyle(.red)
			}
		}
	}

	private var chart: some View {
		Chart {
			ForEach(contents.hours) { hour in
				LineMark(x: .value("Hour", hour.hour, unit: .hour), y: .value("Seconds", hour.seconds))
					.foregroundStyle(by: .value("Source", LogSource.name(hour.source)))
					.interpolationMethod(.monotone)
				// A line needs two hours; the point shows the first one too.
				PointMark(x: .value("Hour", hour.hour, unit: .hour), y: .value("Seconds", hour.seconds))
					.foregroundStyle(by: .value("Source", LogSource.name(hour.source)))
					.symbolSize(16)
				if hour.failedRequests > 0 {
					PointMark(x: .value("Hour", hour.hour, unit: .hour), y: .value("Seconds", hour.seconds))
						.foregroundStyle(.red)
						.symbolSize(30)
				}
			}
			if let pointedHour {
				RuleMark(x: .value("Hour", pointedHour, unit: .hour))
					.foregroundStyle(.secondary.opacity(0.5))
			}
		}
		.chartForegroundStyleScale(["Jenkins": LogSource.color("jenkins"), "GitLab": LogSource.color("gitlab")])
		.chartLegend(.hidden)
		.chartXScale(domain: Date().addingTimeInterval(-86400) ... Date())
		.chartXAxis {
			AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
				AxisGridLine()
				AxisValueLabel(format: .dateTime.hour())
			}
		}
		.chartYAxis {
			AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
				AxisGridLine()
				AxisValueLabel {
					if let seconds = value.as(Double.self) {
						Text(Self.duration(seconds))
					}
				}
			}
		}
		.chartXSelection(value: $pointed)
	}

	static func duration(_ seconds: Double) -> String {
		"\(seconds.formatted(.number.precision(.fractionLength(seconds == 0 || seconds >= 10 ? 0 : seconds < 1 ? 2 : 1)))) s"
	}
}

/// A request to Jenkins or GitLab with its response, as the plugin keeps it (see save_request in
/// plugins/jenkins.30s.sh): without the token and the cookies, and only the start of a big response.
struct RequestRecord: Decodable {
	let method: String
	let url: String
	/// GitLab's GraphQL query and its variables as JSON
	let query: String?
	let variables: String?
	/// curl's exit code: 0 when the server answered
	let exit: Int
	let status: String
	let seconds: Double
	let headers: String
	/// the size of the whole response body, of which body is the start when truncated
	let bytes: Int
	let truncated: Bool
	let body: String

	var requestText: String {
		var text = "\(method) \(url.removingPercentEncoding ?? url)\n"
		if query == nil {
			text += "Authorization: Basic (not kept)"
		} else {
			text += "Authorization: Bearer (not kept)\nContent-Type: application/json"
		}
		if let query {
			text += "\n\n\(query)"
		}
		if let variables, variables != "{}" {
			text += "\n\nVariables: \(JSONText.pretty(variables))"
		}
		return text
	}

	var responseText: String {
		guard exit == 0 else {
			switch exit {
			case 28: return "No answer in time: curl gave up after \(RequestRecord.duration(seconds))."
			case 6: return "No answer: the host is unknown (VPN?)."
			case 7: return "No answer: no connection (VPN?)."
			default: return "No answer: curl failed with error \(exit)."
			}
		}
		// The headers have their own tab: some, like GitLab's security policy, take a page.
		var text = headers.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "HTTP \(status)"
		text += "\n\n\(JSONText.pretty(body))"
		if truncated {
			text += "\n\n… only the first \(Int64(body.utf8.count).formatted(.byteCount(style: .file))) of \(Int64(bytes).formatted(.byteCount(style: .file))) are kept"
		}
		return text
	}

	var headersText: String {
		exit == 0 ? headers : "No headers: no answer."
	}

	/// The request as a curl command, with the token from the environment like the menu reads it.
	var curlCommand: String {
		var parts = ["curl", "-sS"]
		if let query {
			let variables = variables.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? [String: Any]()
			let data = (try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables], options: [.withoutEscapingSlashes])) ?? Data()
			parts += ["-H", "\"Authorization: Bearer $GITLAB_TOKEN\"", "-H", "'Content-Type: application/json'", "-d", Self.quoted(String(decoding: data, as: UTF8.self))]
		} else {
			parts += ["-H", "\"Authorization: Basic $JENKINS_MCP_BASIC_AUTH\""]
		}
		return (parts + [Self.quoted(url)]).joined(separator: " ")
	}

	static func quoted(_ text: String) -> String {
		"'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
	}

	static func duration(_ seconds: Double) -> String {
		"\(seconds.formatted(.number.precision(.fractionLength(2)))) s"
	}
}

enum JSONText {
	/// Indents JSON the way it comes, keeping the order of its keys (JSONSerialization sorts or shuffles them); also the
	/// start of a cut JSON. Text that is not JSON, like an HTML error page, stays as it is.
	static func pretty(_ text: String) -> String {
		let characters = Array(text.unicodeScalars)
		guard let first = characters.first(where: { !$0.properties.isWhitespace }), first == "{" || first == "[" else { return text }
		var result = String.UnicodeScalarView()
		var depth = 0
		var index = 0
		var inString = false
		var escaped = false
		func newLine() {
			result.append("\n")
			result.append(contentsOf: String(repeating: "  ", count: depth).unicodeScalars)
		}
		while index < characters.count {
			let character = characters[index]
			if inString {
				result.append(character)
				if escaped {
					escaped = false
				} else if character == "\\" {
					escaped = true
				} else if character == "\"" {
					inString = false
				}
				index += 1
				continue
			}
			switch character {
			case "\"":
				inString = true
				result.append(character)
			case "{", "[":
				result.append(character)
				// An empty object or array stays on its line.
				var next = index + 1
				while next < characters.count, characters[next].properties.isWhitespace {
					next += 1
				}
				if next < characters.count, characters[next] == "}" || characters[next] == "]" {
					result.append(characters[next])
					index = next
				} else {
					depth += 1
					newLine()
				}
			case "}", "]":
				depth = max(0, depth - 1)
				newLine()
				result.append(character)
			case ",":
				result.append(character)
				newLine()
			case ":":
				result.append(contentsOf: ": ".unicodeScalars)
			case " ", "\n", "\r", "\t":
				break
			default:
				result.append(character)
			}
			index += 1
		}
		return String(result)
	}
}

/// Long text, like a response, in a text view that copes with its size: selectable, with the find bar (⌘F).
struct CodeText: NSViewRepresentable {
	let text: String

	func makeNSView(context: Context) -> NSScrollView {
		let scrollView = NSTextView.scrollableTextView()
		let textView = scrollView.documentView as! NSTextView
		textView.isEditable = false
		textView.isSelectable = true
		textView.usesFindBar = true
		textView.isIncrementalSearchingEnabled = true
		textView.textContainerInset = NSSize(width: 8, height: 10)
		return scrollView
	}

	func updateNSView(_ scrollView: NSScrollView, context: Context) {
		let textView = scrollView.documentView as! NSTextView
		guard textView.string != text else { return }
		textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
			.font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
			.foregroundColor: NSColor.textColor,
		]))
		textView.scroll(.zero)
	}
}

/// The details of a log entry: for a request, the request and the response; for the others, the whole entry.
struct EntryDetails: View {
	enum Part: String, CaseIterable {
		case request = "Request", response = "Response", headers = "Headers"
	}

	let entry: LogEntry
	let request: RequestRecord?
	/// What went wrong, or what came back, is what one looks for first.
	@ViewState private var part = Part.response
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(alignment: .firstTextBaseline, spacing: 10) {
				if let outcome = entry.outcome {
					OutcomePill(outcome: outcome)
				} else {
					LevelIcon(level: entry.level)
				}
				Text(entry.message)
					.font(.headline)
					.textSelection(.enabled)
					.lineLimit(3)
				Spacer()
				SourceTag(source: entry.source)
					.fixedSize()
			}
			if let request {
				HStack(spacing: 12) {
					Picker("Part", selection: $part) {
						ForEach(Part.allCases, id: \.self) { Text($0.rawValue).tag($0) }
					}
					.pickerStyle(.segmented)
					.labelsHidden()
					.fixedSize()
					Text(facts(of: request))
						.foregroundStyle(.secondary)
						.monospacedDigit()
					Spacer()
				}
				CodeText(text: text(of: request))
					.clipShape(RoundedRectangle(cornerRadius: 8))
					.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
			} else {
				if !entry.request.isEmpty {
					Label("The request and its response are gone: only the newest requests keep theirs.", systemImage: "clock.arrow.circlepath")
						.foregroundStyle(.secondary)
				}
				CodeText(text: [entry.time, "\(entry.level.rawValue) · \(LogSource.name(entry.source))", entry.message, entry.detail]
					.filter { !$0.isEmpty }.joined(separator: "\n\n"))
					.clipShape(RoundedRectangle(cornerRadius: 8))
					.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
			}
			HStack {
				if let request {
					Button("Copy \(part.rawValue)") { copy(text(of: request)) }
					Button("Copy as cURL") { copy(request.curlCommand) }
						.help("A curl command for Terminal, with the token from $GITLAB_TOKEN or $JENKINS_MCP_BASIC_AUTH")
				} else {
					Button("Copy") { copy(entry.text) }
				}
				Spacer()
				Button("Done") { dismiss() }
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(20)
		.frame(minWidth: 600, idealWidth: 720, minHeight: 420, idealHeight: 540)
		// Esc closes it too, like Return.
		.onExitCommand { dismiss() }
	}

	private func text(of request: RequestRecord) -> String {
		switch part {
		case .request: request.requestText
		case .response: request.responseText
		case .headers: request.headersText
		}
	}

	private func facts(of request: RequestRecord) -> String {
		var facts = [entry.date.formatted(.dateTime.hour().minute().second()), RequestRecord.duration(request.seconds)]
		if request.exit == 0 {
			facts.append(Int64(request.bytes).formatted(.byteCount(style: .file)))
		}
		return facts.joined(separator: " · ")
	}

	private func copy(_ text: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
	}
}
