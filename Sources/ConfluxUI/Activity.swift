import Charts
import ConfluxCore
import Foundation
import SwiftUI

// The status section's view over time: requests or tokens by the minute,
// stacked by host, and small charts of the device's resources on the same
// span. Both apps show them the same way.

/// How far back the charts look, and how wide each bar is.
public enum ActivityRange: String, CaseIterable, Identifiable, Sendable {
    case hour, day

    public var id: Self { self }
    public var title: String { self == .hour ? "Hour" : "Day" }
    /// Seconds shown.
    public var span: TimeInterval { self == .hour ? 3600 : 86400 }
    /// Seconds in each bar.
    public var bin: TimeInterval { self == .hour ? 60 : 600 }
}

/// What the activity chart counts.
public enum ActivityMetric: String, CaseIterable, Identifiable, Sendable {
    case requests, tokens
    /// The share of each host's slot time spent running requests.
    case utilization

    public var id: Self { self }
    public var title: String {
        switch self {
        case .requests: "Requests"
        case .tokens: "Tokens"
        case .utilization: "Busy"
        }
    }

    func value(_ minute: ActivityMinute) -> Int {
        switch self {
        case .requests: minute.completed
        case .tokens: minute.completionTokens
        case .utilization: 0 // Drawn as a share, not stacked.
        }
    }
}

/// One host's minutes, under the name the chart shows.
public struct ActivitySeries: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let minutes: [ActivityMinute]
    /// The model the host serves, or last served: its minutes count for that
    /// model, even those from before it changed. Nil when unknown.
    public let model: String?
    /// How long its requests typically take.
    public let typicalSeconds: Double?

    public init(id: String, name: String, minutes: [ActivityMinute], model: String? = nil,
                typicalSeconds: Double? = nil) {
        self.id = id
        self.name = name
        self.minutes = minutes
        self.model = model
        self.typicalSeconds = typicalSeconds
    }
}

/// A share, 0 to 1, as a whole percentage.
public func percent(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
}

/// The figure over the chart, a line on how it's going, the choice of what
/// to count and how far back, and the chart.
public struct ActivityPanel: View {
    let series: [ActivitySeries]
    let typicalSeconds: Double?
    let tailSeconds: Double?
    @Binding var metric: ActivityMetric
    @Binding var range: ActivityRange
    let now: Date
    /// Only this model's hosts, or nil for every host.
    @State private var model: String?

    /// `tailSeconds` is the 95th percentile of request time, shown beside
    /// the typical time, which follows the median.
    public init(series: [ActivitySeries], typicalSeconds: Double?, tailSeconds: Double? = nil,
                metric: Binding<ActivityMetric>, range: Binding<ActivityRange>, now: Date = Date()) {
        self.series = series
        self.typicalSeconds = typicalSeconds
        self.tailSeconds = tailSeconds
        self._metric = metric
        self._range = range
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { summary; Spacer(); pickers }
                VStack(alignment: .leading, spacing: 8) { summary; pickers }
            }
            ActivityChart(series: series, metric: metric, range: range, now: now,
                          shown: chosen.map { model in Set(series.filter { $0.model == model }.map(\.id)) })
        }
    }

    /// Every model a host serves or served, Apple's last, when there's more
    /// than one to choose between.
    private var models: [String] {
        let models = Set(series.compactMap(\.model)).sorted {
            ($0 == AppleModelHost.modelID ? 1 : 0, $0) < ($1 == AppleModelHost.modelID ? 1 : 0, $1)
        }
        return models.count > 1 ? models : []
    }

    /// The model chosen, while a host still has it.
    private var chosen: String? { model.flatMap { models.contains($0) ? $0 : nil } }

    private var shownSeries: [ActivitySeries] { chosen.map { model in series.filter { $0.model == model } } ?? series }

    /// For every host, the typical time given. For one model's, its hosts'
    /// typical times, each by how much of the last ten minutes' work it did.
    private func typical(_ series: [ActivitySeries]) -> Double? {
        guard chosen != nil else { return typicalSeconds }
        let weighted = series.compactMap { host in
            host.typicalSeconds.map { typical in
                (typical, Double(ActivityTotals(host.minutes.filter { $0.start > now.addingTimeInterval(-600) }).completed))
            }
        }
        let work = weighted.reduce(0) { $0 + $1.1 }
        guard !weighted.isEmpty else { return nil }
        return work > 0 ? weighted.reduce(0) { $0 + $1.0 * $1.1 } / work
                        : weighted.reduce(0) { $0 + $1.0 } / Double(weighted.count)
    }

    /// The last ten minutes, as a rate: what's happening now. The failures
    /// count over the whole span, to go with the red marks. For the model
    /// chosen, if one is.
    private var summary: some View {
        let series = shownSeries
        let typicalSeconds = typical(series)
        // This Mac's tail: not one model's hosts'.
        let tailSeconds = chosen == nil ? tailSeconds : nil
        let recent = ActivityTotals(series.flatMap { $0.minutes.filter { $0.start > now.addingTimeInterval(-600) } })
        let shown = series.map { host in
            (name: host.name,
             failed: ActivityTotals(host.minutes.filter { $0.start > now.addingTimeInterval(-range.span) }).failed)
        }
        let failed = shown.reduce(0) { $0 + $1.failed }
        let headline: String = switch metric {
        case .requests: "\((recent.completed * 6).formatted()) per hour"
        case .tokens: "\((recent.completionTokens / 10).formatted()) tokens a minute"
        case .utilization: recent.utilization.map { "\(percent($0)) busy" } ?? "No slots offered"
        }
        var parts: [String] = []
        switch metric {
        case .requests:
            if let typicalSeconds {
                parts.append(String(format: "typical request %.1f s", typicalSeconds)
                             + (tailSeconds.map { String(format: ", p95 %.1f s", $0) } ?? ""))
            }
            if let utilization = recent.utilization { parts.append("\(percent(utilization)) busy") }
        case .tokens:
            parts.append("\((recent.promptTokens / 10).formatted()) read")
            if let speed = recent.tokensPerSecond { parts.append(String(format: "%.0f a second while writing", speed)) }
        case .utilization:
            if recent.utilization != nil {
                parts.append(chosen == nil ? "of every host's slots, last ten minutes"
                                           : "of this model's hosts' slots, last ten minutes")
            }
        }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(headline).font(.title2.monospacedDigit().weight(.semibold))
            Text(parts.joined(separator: " · ")).foregroundStyle(.secondary)
            if failed > 0 {
                Text("\(failed) failed").foregroundStyle(.red)
                    .help(shown.filter { $0.failed > 0 }.map { "\($0.name): \($0.failed)" }.joined(separator: ", "))
            }
        }
        .lineLimit(1)
    }

    private var pickers: some View {
        HStack {
            if !models.isEmpty {
                Picker("Model", selection: $model) {
                    Text("Every model").tag(String?.none)
                    Divider()
                    ForEach(models, id: \.self) { model in
                        Text(model == AppleModelHost.modelID ? "Apple's model" : model).tag(Optional(model))
                    }
                }
                .pickerStyle(.menu)
            }
            Group {
                Picker("Count", selection: $metric) {
                    ForEach(ActivityMetric.allCases) { Text($0.title).tag($0) }
                }
                Picker("Over", selection: $range) {
                    ForEach(ActivityRange.allCases) { Text($0.title).tag($0) }
                }
            }
            .pickerStyle(.segmented)
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// Requests or tokens written, a bar for each minute of the last hour or ten
/// minutes of the last day, stacked by host, or each host's share of its
/// slot time busy as a line, with a red mark where a host failed. Selecting
/// a mark says which hosts failed there, and the legend counts each host's.
public struct ActivityChart: View {
    let series: [ActivitySeries]
    let metric: ActivityMetric
    let range: ActivityRange
    let now: Date
    /// The hosts drawn, by ID, or nil for all of them. Each keeps the colour
    /// it has among all of them.
    let shown: Set<String>?
    /// The time selected on the chart, to name the hosts that failed there.
    @State private var selected: Date?

    public init(series: [ActivitySeries], metric: ActivityMetric, range: ActivityRange, now: Date = Date(),
                shown: Set<String>? = nil) {
        self.series = series
        self.metric = metric
        self.range = range
        self.now = now
        self.shown = shown
    }

    /// Each host keeps its colour whatever's shown. Red is kept for
    /// failures.
    static let palette: [Color] = [.blue, .teal, .orange, .yellow, .pink, .green, .purple, .brown]

    struct Segment: Identifiable {
        let id: String
        let name: String
        let start: Date
        let end: Date
        let low: Int
        let high: Int
    }

    /// One host's share of its slot time busy in one bin.
    struct Point: Identifiable {
        var id: String { "\(name)-\(at.timeIntervalSince1970)" }
        let name: String
        let at: Date
        let percent: Double
    }

    /// The failures in one bin, by host.
    struct Failure: Identifiable {
        var id: Date { at }
        let at: Date
        let hosts: [(name: String, count: Int)]

        var label: String {
            let time = at.formatted(date: .omitted, time: .shortened)
            return "\(time): " + hosts.map { "\($0.name) \($0.count) failed" }.joined(separator: ", ")
        }
    }

    private var start: Date { now.addingTimeInterval(-range.span) }

    /// Times on the clock: each quarter hour, or each six hours from
    /// midnight. Striding from the span's start would land on odd minutes.
    private var ticks: [Date] {
        let step: TimeInterval = range == .hour ? 15 * 60 : 6 * 3600
        var tick = Calendar.current.startOfDay(for: start)
        var ticks: [Date] = []
        while tick <= now {
            if tick >= start { ticks.append(tick) }
            tick = tick.addingTimeInterval(step)
        }
        return ticks
    }

    /// A bin's start, for a minute.
    private func bin(_ minute: ActivityMinute) -> Date {
        let seconds = minute.start.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / range.bin).rounded(.down) * range.bin)
    }

    /// A host's minutes in the span, and the bin that started before it.
    private func inRange(_ host: ActivitySeries) -> [ActivityMinute] {
        host.minutes.filter { $0.start >= start.addingTimeInterval(-range.bin) }
    }

    private var stacks: (segments: [Segment], points: [Point], failures: [Failure]) {
        var totals: [Date: Int] = [:]
        var failed: [Date: [(name: String, count: Int)]] = [:]
        var segments: [Segment] = []
        var points: [Point] = []
        let gap = range.bin * 0.12
        for host in series where shown?.contains(host.id) ?? true {
            var values: [Date: Int] = [:]
            var slots: [Date: (busy: Double, offered: Double)] = [:]
            var failures: [Date: Int] = [:]
            for minute in inRange(host) {
                values[bin(minute), default: 0] += metric.value(minute)
                slots[bin(minute), default: (0, 0)].busy += minute.busySlotSeconds
                slots[bin(minute), default: (0, 0)].offered += minute.slotSeconds
                if minute.failed > 0 { failures[bin(minute), default: 0] += minute.failed }
            }
            for (at, count) in failures { failed[at, default: []].append((host.name, count)) }
            if metric == .utilization {
                for (at, slot) in slots.sorted(by: { $0.key < $1.key }) where slot.offered > 0 {
                    points.append(Point(name: host.name, at: at.addingTimeInterval(range.bin / 2),
                                        percent: min(100, slot.busy / slot.offered * 100)))
                }
                continue
            }
            for (at, value) in values.sorted(by: { $0.key < $1.key }) where value > 0 {
                let low = totals[at, default: 0]
                totals[at] = low + value
                segments.append(Segment(id: "\(host.id)-\(at.timeIntervalSince1970)", name: host.name,
                                        start: at.addingTimeInterval(gap / 2),
                                        end: at.addingTimeInterval(range.bin - gap / 2), low: low, high: low + value))
            }
        }
        let failures = failed.keys.sorted().map { Failure(at: $0.addingTimeInterval(range.bin / 2), hosts: failed[$0] ?? []) }
        return (segments, points, failures)
    }

    public var body: some View {
        // With each host's failures on the span, for the legend.
        let entries = series.indices.compactMap { index -> (name: String, color: Color, failed: Int)? in
            guard shown?.contains(series[index].id) ?? true else { return nil }
            let failed = inRange(series[index]).filter { $0.start >= start }.reduce(0) { $0 + $1.failed }
            return (series[index].name, index < Self.palette.count ? Self.palette[index] : Color.gray, failed)
        }
        let names = entries.map(\.name)
        let colors = entries.map(\.color)
        let failed = entries.map(\.failed)
        VStack(alignment: .leading, spacing: 6) {
            chart(names: names, colors: colors)
                .frame(height: 116)
            // Its own, not the chart's, which keeps to one line and cuts off
            // the hosts that don't fit.
            if series.count > 1 || failed.contains(where: { $0 > 0 }) {
                Flow {
                    ForEach(Array(zip(names, colors).enumerated()), id: \.offset) { index, entry in
                        HStack(spacing: 4) {
                            Circle().fill(entry.1).frame(width: 7, height: 7)
                            Text(entry.0).lineLimit(1).truncationMode(.middle)
                            if failed[index] > 0 {
                                Text("\(failed[index]) failed").foregroundStyle(.red)
                            }
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
        }
    }

    private var empty: String {
        switch metric {
        case .requests: "No requests yet"
        case .tokens: "No tokens yet"
        case .utilization: "No slots offered yet"
        }
    }

    private func chart(names: [String], colors: [Color]) -> some View {
        let (segments, points, failures) = stacks
        let top = metric == .utilization ? 100 : max(segments.map(\.high).max() ?? 0, metric == .requests ? 4 : 100)
        let pointed = selected.flatMap { selected in
            failures.first { abs($0.at.timeIntervalSince(selected)) <= range.bin / 2 }
        }
        return Chart {
            ForEach(segments) { segment in
                RectangleMark(xStart: .value("Time", segment.start), xEnd: .value("Time", segment.end),
                              yStart: .value(metric.title, segment.low), yEnd: .value(metric.title, segment.high))
                    .foregroundStyle(by: .value("Host", segment.name))
            }
            ForEach(points) { point in
                LineMark(x: .value("Time", point.at), y: .value(metric.title, point.percent))
                    .foregroundStyle(by: .value("Host", point.name))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(failures) { failure in
                PointMark(x: .value("Time", failure.at), y: .value(metric.title, 0))
                    .foregroundStyle(.red)
                    .symbolSize(28)
                    .accessibilityLabel(failure.label)
            }
            if let pointed {
                RuleMark(x: .value("Time", pointed.at))
                    .foregroundStyle(.red.opacity(0.3))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text(pointed.label)
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 4))
                    }
            }
        }
        .chartForegroundStyleScale(domain: names, range: colors)
        .chartXScale(domain: start...now)
        .chartYScale(domain: 0...top)
        .chartXSelection(value: $selected)
        .chartXAxis {
            AxisMarks(values: ticks) { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            if metric == .utilization {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
        }
        .chartLegend(.hidden)
        .overlay {
            if segments.isEmpty && points.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        switch metric {
        case .requests: "Requests completed over time, by host"
        case .tokens: "Tokens written over time, by host"
        case .utilization: "Share of each host's slot time spent running requests, over time"
        }
    }
}

/// Views left to right, onto as many lines as they need. One wider than a
/// line gets the line, and truncates.
struct Flow: Layout {
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(subviews, width: bounds.width).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width {
                x = 0
                y += line + lineSpacing
                line = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            line = max(line, size.height)
        }
        return (frames, CGSize(width: widest, height: y + line))
    }
}

// MARK: Resources

/// A reading taken over and over: memory, heat, power, requests waiting.
/// Readings closer together than `interval` count as one, so it can be fed
/// every second and keep a day without growing past a few thousand.
public struct TimeSeries: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        public var date: Date
        public var value: Double
    }

    /// Within an interval, and within a bin: the last reading and the
    /// average, the highest, or the lowest.
    public enum Merge: Sendable { case latest, highest, lowest }

    public private(set) var samples: [Sample] = []
    let interval: TimeInterval
    let merge: Merge
    static let kept: TimeInterval = 86400

    public init(every interval: TimeInterval = 15, keeping merge: Merge = .latest) {
        self.interval = interval
        self.merge = merge
    }

    public var latest: Double? { samples.last?.value }

    public mutating func append(_ value: Double, at date: Date = Date()) {
        if let last = samples.indices.last, date.timeIntervalSince(samples[last].date) < interval,
           date >= samples[last].date {
            switch merge {
            case .latest: samples[last].value = value
            case .highest: samples[last].value = max(samples[last].value, value)
            case .lowest: samples[last].value = min(samples[last].value, value)
            }
            return
        }
        samples.append(Sample(date: date, value: value))
        if let first = samples.first, date.timeIntervalSince(first.date) > Self.kept + interval {
            samples.removeAll { date.timeIntervalSince($0.date) > Self.kept }
        }
    }

    public struct Bin: Identifiable, Sendable, Equatable {
        public var id: Date { start }
        public let start: Date
        public let end: Date
        /// Nil where there was no reading.
        public let value: Double?
    }

    /// The span ending at `now` in `count` equal bins, each the average of
    /// its readings, the highest or the lowest.
    public func bins(_ range: ActivityRange, until now: Date = Date(), count: Int = 60) -> [Bin] {
        let width = range.span / Double(count)
        let start = now.addingTimeInterval(-range.span)
        var groups = [[Double]](repeating: [], count: count)
        for sample in samples where sample.date >= start && sample.date <= now {
            let index = min(count - 1, Int(sample.date.timeIntervalSince(start) / width))
            groups[index].append(sample.value)
        }
        return groups.indices.map { index in
            let values = groups[index]
            let value: Double? = switch merge {
            case _ where values.isEmpty: nil
            case .latest: values.reduce(0, +) / Double(values.count)
            case .highest: values.max()
            case .lowest: values.min()
            }
            let from = start.addingTimeInterval(Double(index) * width)
            return Bin(start: from, end: from.addingTimeInterval(width), value: value)
        }
    }
}

/// A small line over time, with no axes: its shape is the point.
public struct Sparkline: View {
    let bins: [TimeSeries.Bin]
    let color: Color
    let ceiling: Double?

    public init(_ bins: [TimeSeries.Bin], color: Color = .blue, ceiling: Double? = nil) {
        self.bins = bins
        self.color = color
        self.ceiling = ceiling
    }

    /// Bins with readings, each with the run it belongs to: a gap with no
    /// readings breaks the line.
    private var points: [(bin: TimeSeries.Bin, value: Double, run: Int)] {
        var run = 0, previous = true
        var points: [(TimeSeries.Bin, Double, Int)] = []
        for bin in bins {
            if let value = bin.value {
                if !previous { run += 1 }
                points.append((bin, value, run))
                previous = true
            } else {
                previous = false
            }
        }
        return points
    }

    public var body: some View {
        let points = points
        let top = max(ceiling ?? 0, points.map(\.value).max() ?? 0, 1)
        Chart {
            ForEach(points, id: \.bin.id) { point in
                AreaMark(x: .value("Time", point.bin.start), y: .value("Value", point.value),
                         series: .value("Run", point.run))
                    .foregroundStyle(color.opacity(0.15))
                LineMark(x: .value("Time", point.bin.start), y: .value("Value", point.value),
                         series: .value("Run", point.run))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .chartXScale(domain: (bins.first?.start ?? Date())...(bins.last?.end ?? Date()))
        .chartYScale(domain: 0...top)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 28)
        .accessibilityHidden(true)
    }
}

/// A reading with a few levels, such as thermal state, as a strip of bars:
/// taller and warmer the higher the level.
public struct LevelBand: View {
    let bins: [TimeSeries.Bin]
    let colors: [Color]

    public init(_ bins: [TimeSeries.Bin], colors: [Color]) {
        self.bins = bins
        self.colors = colors
    }

    public var body: some View {
        let levels = max(colors.count, 1)
        Chart {
            ForEach(bins.filter { $0.value != nil }) { bin in
                let level = min(levels - 1, max(0, Int(bin.value ?? 0)))
                RectangleMark(xStart: .value("Time", bin.start), xEnd: .value("Time", bin.end),
                              yStart: .value("Level", 0), yEnd: .value("Level", level + 1))
                    .foregroundStyle(colors.isEmpty ? Color.gray : colors[level])
            }
        }
        .chartXScale(domain: (bins.first?.start ?? Date())...(bins.last?.end ?? Date()))
        .chartYScale(domain: 0...levels)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 28)
        .accessibilityHidden(true)
    }
}

/// One resource: what it's called, where it stands, and how it's gone, with
/// an optional control beside its name.
public struct ResourceTile<Chart: View, Accessory: View>: View {
    let title: String
    let value: String
    let chart: Chart
    let accessory: Accessory

    public init(_ title: String, value: String, @ViewBuilder accessory: () -> Accessory,
                @ViewBuilder chart: () -> Chart) {
        self.title = title
        self.value = value
        self.chart = chart()
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold)).lineLimit(1)
            chart
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        // Over the name's line, so the tile is no taller, and outside the
        // combined element, so it stays a control of its own.
        .overlay(alignment: .topTrailing) { accessory }
    }
}

extension ResourceTile where Accessory == EmptyView {
    public init(_ title: String, value: String, @ViewBuilder chart: () -> Chart) {
        self.init(title, value: value, accessory: { EmptyView() }, chart: chart)
    }
}

/// The Heat tile: the thermal state, what resource policy is doing about it,
/// and the Cool down box (`ResourcePolicy.heat`).
public struct HeatTile: View {
    let status: HeatStatus
    let bins: [TimeSeries.Bin]
    let setCoolDown: @MainActor @Sendable (Bool) -> Void

    public init(_ status: HeatStatus, bins: [TimeSeries.Bin],
                setCoolDown: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.status = status
        self.bins = bins
        self.setCoolDown = setCoolDown
    }

    public var body: some View {
        ResourceTile("Heat", value: Thermal.label.capitalized + (status.action.map { " · \($0)" } ?? "")) {
            CoolDownBox(status, set: setCoolDown)
        } chart: {
            LevelBand(bins, colors: thermalColors)
        }
    }
}

/// Checked to rest this device's hosts at serious heat until it's back to
/// fair. Checked and dimmed while resource policy has paused them itself.
struct CoolDownBox: View {
    let status: HeatStatus
    let set: @MainActor @Sendable (Bool) -> Void

    init(_ status: HeatStatus, set: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.status = status
        self.set = set
    }

    private var help: String {
        status.box == .automatic
            ? "conflux has paused this device's models by itself, until it's cooler or has more memory"
            : "Rest this device's models when its heat reaches serious, until it's back to fair. Heat ages the battery."
    }

    var body: some View {
        let isOn = Binding(get: { status.box != .off }, set: set)
        Toggle("Cool down", isOn: isOn)
            #if os(macOS)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            #else
            .toggleStyle(CheckboxStyle())
            #endif
            .font(.subheadline)
            .disabled(status.box == .automatic)
            .help(help)
    }
}

#if !os(macOS)
/// A checkbox, which iPadOS doesn't have: a square that fills with a check.
/// The label is part of what's tapped, so it's big enough for a finger.
struct CheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Label {
                configuration.label.foregroundStyle(isEnabled ? .primary : .secondary)
            } icon: {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
            }
            .contentShape(Rectangle())
        }
        // Borderless, so in a list row only the box answers a tap, not the
        // whole row.
        .buttonStyle(.borderless)
        .accessibilityValue(configuration.isOn ? "checked" : "unchecked")
    }
}
#endif

/// How the thermal state is drawn: nominal, fair, serious, critical.
public let thermalColors: [Color] = [.green, .yellow, .orange, .red]

extension Thermal {
    /// The thermal state as a level, 0 for nominal to 3 for critical.
    public static var level: Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        @unknown default: 0
        }
    }
}

/// This process's memory footprint: what the system counts against it.
/// With the model run in the process, nearly all of it is the model.
public enum ProcessMemory {
    public static var footprint: (now: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak)))
    }

    public static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }
}
