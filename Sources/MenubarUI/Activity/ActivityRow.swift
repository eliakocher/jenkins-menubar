import MenubarCore
import SwiftUI

/// One row of the Activity list, the old Logs' look (LOG-04; the user, 2026-10-29, "old look, new brains"): the time,
/// the outcome as a pill (or, without one, a warning's or an error's symbol), the source as a pill, the message with
/// its detail under it, and for an entry with a request an ⓘ that opens the inspector. In a narrow list the time and
/// the pills go on a line of their own above the message.
struct ActivityRow: View {
    let item: ActivityItem
    /// whether the list is too narrow for the columns side by side
    var isCompact = false
    /// opens the inspector with this entry; the ⓘ shows only for an entry with a request
    let inspect: @MainActor () -> Void
    /// below this list width the rows put the time and the pills above the message: the columns take about 280 pt
    nonisolated static let compactListWidth: CGFloat = 520
    @ScaledMetric(relativeTo: .caption) private var outcomeWidth = 92.0
    @ScaledMetric(relativeTo: .caption) private var sourceWidth = 64.0

    var body: some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    time
                    marker
                    source
                    Spacer(minLength: 0)
                    infoButton
                }
                message
            }
            .padding(.vertical, 2)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                time
                // An HStack, not a Group: empty, it still takes the column's width, so the source pills line up.
                HStack(spacing: 0) {
                    marker
                }
                .frame(width: outcomeWidth, alignment: .leading)
                source
                    .frame(width: sourceWidth, alignment: .leading)
                message
                Spacer(minLength: 0)
                infoButton
            }
            .padding(.vertical, 2)
        }
    }

    /// "10:41:07", as wide as the widest time of the day, so the pills of every row line up.
    private var time: some View {
        ZStack(alignment: .leading) {
            Text(verbatim: Self.widestTime)
                .hidden()
            Text(verbatim: item.entry.time.formatted(date: .omitted, time: .standard))
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    /// The outcome's pill, or without one, a warning's or an error's symbol.
    @ViewBuilder
    private var marker: some View {
        if let outcome = item.entry.outcome {
            ActivityPill(text: outcome.label, symbol: ActivityPillTint.symbol(of: outcome.kind), tint: .init(outcome))
        } else if let symbol = ActivityLevelSymbol(item.entry.level) {
            ActivityLevelImage(symbol: symbol)
        }
    }

    private var source: some View {
        ActivityPill(text: item.entry.source.displayName, tint: .init(item.entry.source))
    }

    /// The message, debug ones in `.secondary`, with the detail under it; the tooltip has both in full.
    private var message: some View {
        let entry = item.entry
        let text = item.displayMessage
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: text)
                .foregroundStyle(entry.level == .debug ? .secondary : .primary)
                .lineLimit(3)
            if let detail = entry.detail {
                Text(verbatim: detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .help(entry.detail.map { "\(text)\n\($0)" } ?? text)
    }

    @ViewBuilder
    private var infoButton: some View {
        if item.hasRequest {
            Button(action: inspect) {
                Label("Show Details", systemImage: "info.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Show the request and the response")
        }
    }

    /// 22:22:22 in the user's time format, the widest time of the day in most fonts' digits
    private static let widestTime: String = {
        var components = DateComponents()
        components.hour = 22
        components.minute = 22
        components.second = 22
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .standard)
    }()
}

/// The tint of a warning's or an error's row: "Warnings and errors tinted" (LOG-04), as the old Logs did; nil for
/// debug and info.
enum ActivityRowTint {
    static func color(of level: ActivityEntry.Level) -> Color? {
        switch level {
        case .error: Color.red.opacity(0.08)
        case .warning: Color.orange.opacity(0.07)
        case .debug, .info: nil
        }
    }
}

/// The color family of an Activity pill (LOG-04): OK and 2xx green, problems red, Jenkins blue, GitLab orange, all
/// others neutral. The text is always there, so color is never alone.
enum ActivityPillTint: Hashable {
    case success
    case problem
    case jenkins
    case gitlab
    case neutral

    /// The outcome's tint: a success (`ok:200`, `ok:OK`, `ok:RESOLVED`) green; a failure or a warning (`failed:TIMEOUT`,
    /// `warning:SLOW`) red; running and neutral outcomes neutral, so blue stays Jenkins'.
    init(_ outcome: ActivityEntry.Outcome) {
        switch outcome.kind {
        case .ok: self = .success
        case .failed, .warning: self = .problem
        case .running, .neutral: self = .neutral
        }
    }

    /// The source's tint: Jenkins blue, GitLab orange, Alerts, Settings and App neutral.
    init(_ source: ActivityEntry.Source) {
        switch source {
        case .jenkins: self = .jenkins
        case .gitlab: self = .gitlab
        case .alerts, .settings, .app: self = .neutral
        }
    }

    /// the system color of the tint; nil for neutral, which takes the hierarchical styles
    var color: Color? {
        switch self {
        case .success: .green
        case .problem: .red
        case .jenkins: .blue
        case .gitlab: .orange
        case .neutral: nil
        }
    }

    /// how far the text moves from the system color toward black in light: the green and the orange are the palest
    var lightDeepening: Double {
        switch self {
        case .success: 0.4
        case .gitlab: 0.3
        case .problem, .jenkins: 0.2
        case .neutral: 0
        }
    }

    /// The small symbol in front of an outcome's text, the old Logs' shapes.
    static func symbol(of kind: ActivityEntry.Outcome.Kind) -> String {
        switch kind {
        case .ok: "checkmark"
        case .failed: "xmark"
        case .warning: "exclamationmark"
        case .running: "play.fill"
        case .neutral: "minus"
        }
    }
}

/// A small capsule with a text, and maybe a symbol, in its tint's color on a light fill of it. On a selected row of
/// the focused list the colors give way to the selection's, the text and the shape stay [color › Inclusive color].
struct ActivityPill: View {
    let text: String
    var symbol: String?
    let tint: ActivityPillTint
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.heavy))
                    .imageScale(.small)
            }
            Text(verbatim: text)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(fill, in: Capsule())
    }

    private var isOnSelection: Bool {
        prominence == .increased
    }

    /// The text in the tint's color; in light a touch deeper, so the pale green and orange hold on their fill, and
    /// still vivid, never grey (the user, 2026-10-29: pretty over strict contrast).
    private var foreground: AnyShapeStyle {
        guard !isOnSelection, let color = tint.color else {
            return AnyShapeStyle(.secondary)
        }
        guard colorScheme == .light else {
            return AnyShapeStyle(color)
        }
        return AnyShapeStyle(color.mix(with: .black, by: tint.lightDeepening))
    }

    private var fill: AnyShapeStyle {
        guard !isOnSelection, let color = tint.color else {
            return AnyShapeStyle(.quaternary)
        }
        return AnyShapeStyle(color.opacity(0.16))
    }
}

/// The symbol of a warning or an error, the `status-icon` vocabulary's warning and problem marker.
struct ActivityLevelSymbol {
    let name: String
    let color: Color
    /// "warning" or "error", the symbol's tooltip
    let word: String

    init?(_ level: ActivityEntry.Level) {
        switch level {
        case .warning:
            name = "exclamationmark.triangle"
            color = .orange
            word = "Warning"
        case .error:
            name = "exclamationmark.circle"
            color = .red
            word = "Error"
        case .debug, .info:
            return nil
        }
    }
}

/// A warning's or an error's symbol in its color, `.secondary` on a selected row of the focused list.
struct ActivityLevelImage: View {
    let symbol: ActivityLevelSymbol
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: symbol.name)
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(symbol.color))
            .help(symbol.word)
    }
}
