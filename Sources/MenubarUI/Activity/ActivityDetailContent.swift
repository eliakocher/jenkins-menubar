import MenubarCore
import SwiftUI

/// The Activity inspector drawn from plain values, for the window and the gallery: "No Entry Selected",
/// "3 Entries Selected", or the one entry; blank while the list shows an empty state or placeholders.
struct ActivityDetailPane: View {
    let detail: ActivitySelection.Detail
    /// the details of the one entry; nil while they are read
    let details: ActivityDetails?
    @Binding var tab: RequestDetailTab
    /// whether the list is empty or not read yet; then the inspector stays blank without a selection
    var isListEmpty = false
    var now = Date()
    let copyCurl: @MainActor (RequestDetails) -> Void

    var body: some View {
        switch detail {
        case .none:
            if isListEmpty {
                Color.clear
            } else {
                ContentUnavailableView {
                    Text(MainWindowSection.activity.noSelectionTitle)
                }
            }
        case .several(let count):
            ContentUnavailableView {
                Text(verbatim: "\(count) Entries Selected")
            }
        case .one(let item):
            ActivityDetailContent(
                item: item, details: details?.item.id == item.id ? details : nil, tab: $tab, now: now, copyCurl: copyCurl)
        }
    }
}

/// One entry: its pills, message and facts, Copy as cURL; then its request's parts, or the whole entry, with a note
/// when its request is gone (LOG-02, LOG-04).
struct ActivityDetailContent: View {
    let item: ActivityItem
    /// nil while the store reads them
    let details: ActivityDetails?
    @Binding var tab: RequestDetailTab
    var now = Date()
    let copyCurl: @MainActor (RequestDetails) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content(of: shown)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// An entry without a request needs nothing read, so its details show at once.
    private var shown: ActivityDetails? {
        details ?? (item.hasRequest ? nil : ActivityDetails(item: item, request: nil))
    }

    @ViewBuilder
    private func content(of details: ActivityDetails?) -> some View {
        if let details {
            if let request = details.request {
                RequestDetailView(request: request, tab: $tab)
            } else {
                if details.requestIsGone {
                    Label {
                        Text(verbatim: ActivityDetails.goneMessage)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                // The whole entry, as the old Logs showed one without a request.
                ActivityTextBox(text: item.fullText())
            }
        } else {
            // The store is reading the request: a spinner in the parts' place, never over the whole pane (OD-01).
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let outcome = item.entry.outcome {
                    ActivityPill(
                        text: outcome.label, symbol: ActivityPillTint.symbol(of: outcome.kind), tint: .init(outcome))
                }
                ActivityPill(text: item.entry.source.displayName, tint: .init(item.entry.source))
                if let symbol = ActivityLevelSymbol(item.entry.level) {
                    ActivityLevelImage(symbol: symbol)
                }
            }
            Text(verbatim: item.displayMessage)
                .font(.headline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: ActivityDetailText.facts(of: item.entry, request: shown?.request, now: now))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let request = shown?.request {
                Button("Copy as cURL") { copyCurl(request) }
                    .help("Copy the request as a curl command; the token stays a variable, $JENKINS_MCP_BASIC_AUTH or $GITLAB_TOKEN")
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The texts of the inspector's header.
enum ActivityDetailText {
    /// "warning · 10:41:07", the level and the time; for a kept request with its seconds and size,
    /// "debug · 10:41:07 · 0.18 s · 2 KB", and what of a cut answer is kept: "… · 330 KB · 2 KB kept".
    static func facts(of entry: ActivityEntry, request: RequestDetails?, now: Date, calendar: Calendar = .current) -> String {
        var parts = [entry.level.rawValue, time(of: entry.time, request: request, now: now, calendar: calendar)]
        if let record = request?.record, record.truncated {
            parts.append("\(Int64(record.body.utf8.count).formatted(.byteCount(style: .file))) kept")
        }
        return parts.joined(separator: " · ")
    }

    /// "10:41:07", "Yesterday 18:02:11" or "Tue 27 Oct 09:12:03"; for a kept request with its seconds and size,
    /// "10:41:07 · 0.18 s · 2 KB" (`RequestDetails.facts`).
    static func time(of time: Date, request: RequestDetails?, now: Date, calendar: Calendar = .current) -> String {
        var clock = Date.FormatStyle(date: .omitted, time: .standard)
        clock.calendar = calendar
        clock.timeZone = calendar.timeZone
        var text = time.formatted(clock)
        if !calendar.isDate(time, inSameDayAs: now) {
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(time, inSameDayAs: yesterday) {
                text = "Yesterday \(text)"
            } else {
                var day = Date.FormatStyle.dateTime.weekday().day().month()
                day.calendar = calendar
                day.timeZone = calendar.timeZone
                text = "\(time.formatted(day)) \(text)"
            }
        }
        guard let request else { return text }
        // The request's facts start with the bare time; the day goes in front of it.
        let facts = request.facts(time: time, timeZone: calendar.timeZone).components(separatedBy: " · ")
        return ([text] + facts.dropFirst()).joined(separator: " · ")
    }
}
