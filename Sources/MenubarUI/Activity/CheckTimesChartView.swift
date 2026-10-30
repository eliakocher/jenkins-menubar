import Charts
import MenubarCore
import SwiftUI

/// The check times of the last 24 hours at the top of the Activity section, the old Logs' chart (LOG-04; the user,
/// 2026-10-29): one line per source in its color, Jenkins blue and GitLab orange; an hour with failed requests marked
/// with a red `xmark.circle.fill`; the legend at the top right says per source "avg 0.64 s" and "N failed" for the 24
/// hours, or for the hour under the pointer. In a disclosure group, so the list can take the room.
///
/// Named so, not `CheckTimesChart`, because MenubarCore has a struct of that name: the data it draws.
struct CheckTimesChartView: View {
    let chart: CheckTimesChart
    /// whether the files were read once; before that, the legend shows placeholders
    var isLoaded = true
    @Binding var isExpanded: Bool
    /// the time under the pointer, as `chartXSelection` gives it; nil without a pointer over the chart
    @Binding var hoveredTime: Date?
    var calendar = Calendar.current
    @ScaledMetric(relativeTo: .body) private var plotHeight = 110.0
    /// the plot's width, for how many hours the axis labels
    @ViewState private var plotWidth: CGFloat = 0

    var body: some View {
        // The chevron sits with the title, so the title is the whole label whenever it can be: the legend goes at its
        // right, on one line; in a narrow window it moves into the group, over the plot.
        ViewThatFits(in: .horizontal) {
            DisclosureGroup(isExpanded: $isExpanded) {
                plot
                    .padding(.top, 6)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    title
                    Spacer(minLength: 12)
                    legend(axis: .horizontal)
                }
                .lineLimit(1)
            }
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    legend(axis: .vertical)
                    plot
                }
                .padding(.top, 6)
            } label: {
                title
                    .lineLimit(1)
            }
        }
    }

    /// "Check Times" and "Last 24 hours", or the hour under the pointer.
    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Check Times")
                .font(.headline)
            Text(verbatim: hoveredHour.map(hourText) ?? "Last 24 hours")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Legend

    /// The 24 hours' or the hovered hour's average and failed requests, a line per source: side by side at the title's
    /// right, or one under the other.
    @ViewBuilder
    private func legend(axis: Axis) -> some View {
        if !isLoaded {
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            layout {
                SkeletonBlock(width: 190, height: 9, lineHeight: 16)
                SkeletonBlock(width: 190, height: 9, lineHeight: 16)
            }
            .skeletonShimmer(announces: false)
        } else if !chart.isEmpty {
            legendLines(chart.sources.map { chart.summary(of: $0, hour: hoveredHour) }, axis: axis)
        }
    }

    private func legendLines(_ summaries: [CheckTimesChart.Summary], axis: Axis) -> some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
        return layout {
            ForEach(summaries, id: \.source) { summary in
                legendLine(summary)
            }
        }
        .fixedSize()
    }

    /// "● Jenkins avg 0.64 s ⓧ 4 failed"; "–" for an hour without checks.
    private func legendLine(_ summary: CheckTimesChart.Summary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle()
                .fill(Self.color(of: summary.source))
                .frame(width: 8, height: 8)
            Text(verbatim: summary.source.displayName)
            Text(verbatim: summary.averageText)
                .foregroundStyle(.secondary)
            if let failed = summary.failedText {
                // Never color alone: the mark and the words say it too [charts › Color].
                HStack(spacing: 2) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(verbatim: failed)
                }
            }
        }
        .font(.subheadline)
        .monospacedDigit()
    }

    // MARK: - Plot

    @ViewBuilder
    private var plot: some View {
        if isLoaded, chart.isEmpty {
            Text(verbatim: CheckTimesChart.emptyMessage)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            lines
                .frame(height: plotHeight)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    plotWidth = width
                }
        }
    }

    /// The lines, a point per hour with checks, so a single hour shows too; red marks for failed hours; the hovered
    /// hour as a rule.
    private var lines: some View {
        Chart {
            ForEach(isLoaded ? chart.hours : []) { hour in
                let name = hour.source.displayName
                LineMark(x: .value("Hour", hour.start, unit: .hour), y: .value("Seconds", hour.averageSeconds))
                    .foregroundStyle(by: .value("Source", name))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Hour", hour.start, unit: .hour), y: .value("Seconds", hour.averageSeconds))
                    .foregroundStyle(by: .value("Source", name))
                    .symbolSize(16)
                if hour.failedRequests > 0 {
                    PointMark(x: .value("Hour", hour.start, unit: .hour), y: .value("Seconds", hour.averageSeconds))
                        .symbol {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.white, .red)
                        }
                }
            }
            if let hoveredHour {
                RuleMark(x: .value("Hour", hoveredHour, unit: .hour))
                    .foregroundStyle(.secondary)
            }
        }
        .chartForegroundStyleScale(domain: sourceNames, range: sourceColors)
        .chartLegend(.hidden)
        .chartXScale(domain: timeDomain)
        .chartYScale(domain: 0...secondsTop)
        .chartXAxis {
            AxisMarks(values: axisHours) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text(verbatim: CheckTimesChart.duration(seconds))
                    }
                }
            }
        }
        .chartXSelection(value: $hoveredTime)
    }

    /// the names of the sources with checks, the color scale's domain
    private var sourceNames: [String] {
        chart.sources.map(\.displayName)
    }

    /// the sources' colors, in the order of ``sourceNames``
    private var sourceColors: [Color] {
        chart.sources.map(Self.color)
    }

    /// Jenkins blue, GitLab orange, as their pills; gray for any other source.
    private static func color(of source: ActivityEntry.Source) -> Color {
        ActivityPillTint(source).color ?? .gray
    }

    /// From the start of the hour 24 hours ago to the end of the current hour, so the oldest and newest points show.
    private var timeDomain: ClosedRange<Date> {
        let end = chart.since.addingTimeInterval(CheckTimesChart.window)
        let start = calendar.dateInterval(of: .hour, for: chart.since)?.start ?? chart.since
        let last = calendar.dateInterval(of: .hour, for: end)?.end ?? end
        return start...last
    }

    /// The axis' hours: every third hour of the clock (00:00, 03:00, …), every sixth or twelfth in a narrow plot so the
    /// labels don't run into each other, and none within an hour of either end, so no label is cut at the plot's edge.
    private var axisHours: [Date] {
        let stride = plotWidth >= 560 ? 3 : plotWidth >= 280 ? 6 : 12
        let domain = timeDomain
        var hours: [Date] = []
        var hour = domain.lowerBound
        while hour <= domain.upperBound {
            let isInside = hour.timeIntervalSince(domain.lowerBound) >= 3600 && domain.upperBound.timeIntervalSince(hour) >= 3600
            if isInside, calendar.component(.hour, from: hour) % stride == 0 {
                hours.append(hour)
            }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
            hour = next
        }
        return hours
    }

    /// The top of the seconds axis: a whole number of seconds above every point, at least 1.
    private var secondsTop: Double {
        max(1, (chart.hours.map(\.averageSeconds).max() ?? 1).rounded(.up))
    }

    /// The start of the hour under the pointer, within the 24 hours.
    private var hoveredHour: Date? {
        guard let hoveredTime, timeDomain.contains(hoveredTime) else { return nil }
        return calendar.dateInterval(of: .hour, for: hoveredTime)?.start
    }

    /// "09:00–10:00", in the user's time format.
    private func hourText(_ start: Date) -> String {
        let end = start.addingTimeInterval(3600)
        let style = Date.FormatStyle.dateTime.hour().minute()
        return "\(start.formatted(style))–\(end.formatted(style))"
    }
}
