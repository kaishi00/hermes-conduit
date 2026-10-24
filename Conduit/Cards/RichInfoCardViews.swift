//
//  RichInfoCardViews.swift
//  Conduit
//
//  How the information cards look: stats, a chart, a forecast, a
//  comparison and steps. Each sits on the same surface as the map cards
//  and ends by saying where its information is from: the source Hermes
//  named, as a link when it gave one, or Hermes itself.
//

import Charts
import CryptoKit
import SwiftUI
import UserNotifications

/// A card's heading and its "where it's from" line around its content.
struct RichInfoCardFrame<Content: View>: View {
    let title: String?
    let source: RichCardSource?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(verbatim: title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            content
            RichInfoSourceLine(source: source)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .richCardSurface()
    }
}

/// Where a card's information is from.
struct RichInfoSourceLine: View {
    let source: RichCardSource?

    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let source, let url = source.url {
                Button {
                    openURL(url)
                } label: {
                    Label {
                        Text("Source: \(source.name)").underline()
                    } icon: {
                        Image(systemName: "link")
                    }
                }
                .buttonStyle(.plain)
            } else if let source {
                Label {
                    Text("Source: \(source.name)")
                } icon: {
                    Image(systemName: "doc.text")
                }
            } else {
                Label {
                    Text("From Hermes")
                } icon: {
                    Image(systemName: "text.bubble")
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .labelStyle(RichCompactLabelStyle())
    }
}

// MARK: - Stats

struct RichStatsCard: View {
    let card: RichCard

    var body: some View {
        RichInfoCardFrame(title: card.title, source: card.source) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(Array(card.stats.enumerated()), id: \.offset) { _, stat in
                    RichStatTile(stat: stat)
                }
            }
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .topLeading), count: card.stats.count > 1 ? 2 : 1)
    }
}

private struct RichStatTile: View {
    let stat: RichStat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: stat.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: stat.value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if stat.change != nil || stat.trend != nil {
                HStack(spacing: 3) {
                    if let trend = stat.trend {
                        Image(systemName: Self.symbol(trend))
                            .font(.caption2.weight(.bold))
                            .accessibilityHidden(true)
                    }
                    if let change = stat.change {
                        Text(verbatim: change)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(toneColor)
            }
            if let detail = stat.detail {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !stat.spark.isEmpty {
                RichSparkline(values: stat.spark, color: stat.tone == .neutral ? Color.conduitAccent : toneColor)
                    .frame(height: 28)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var toneColor: Color {
        switch stat.tone {
        case .good: .green
        case .bad: .red
        case .neutral: .secondary
        }
    }

    static func symbol(_ trend: RichStat.Trend) -> String {
        switch trend {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .flat: "arrow.right"
        }
    }
}

private struct RichSparkline: View {
    let values: [Double]
    let color: Color

    private static let xName = "x"
    private static let yName = "y"

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                LineMark(x: .value(Self.xName, index), y: .value(Self.yName, value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(color)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartLegend(.hidden)
    }
}

// MARK: - Chart

struct RichChartCard: View {
    let card: RichCard

    var body: some View {
        if let chart = card.chart {
            RichInfoCardFrame(title: card.title, source: card.source) {
                RichChartView(chart: chart)
            }
        }
    }
}

private struct RichChartView: View {
    let chart: RichChart

    private struct Point: Identifiable {
        let id: String
        let label: String
        let value: Double
        let series: String
    }

    @ScaledMetric(relativeTo: .body) private var plotHeight: CGFloat = 210
    @ScaledMetric(relativeTo: .body) private var pieSize: CGFloat = 150

    var body: some View {
        // A pie of nothing but zeros has no slices, so it's drawn as bars.
        if chart.kind == .pie, (chart.series.first?.values.reduce(0, +) ?? 0) > 0 {
            pie
        } else {
            plot
                .frame(height: plotHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: spokenSummary))
        }
    }

    /// Every series' values with their labels, for VoiceOver.
    private var spokenSummary: String {
        let unit = chart.unit.map { " \($0)" } ?? ""
        return chart.series.map { series -> String in
            let values = zip(chart.labels, series.values)
                .map { "\($0.0) \($0.1.formatted(.number.locale(AppLocalization.formattingLocale)))\(unit)" }
                .joined(separator: ", ")
            return series.name.map { "\($0): \(values)" } ?? values
        }
        .joined(separator: "; ")
    }

    // Plain strings, not catalog keys: Charts uses them only to tell the
    // marks' values apart.
    private static let labelName = "Label"
    private static let seriesName = "Series"
    private var valueName: String { chart.unit ?? "Value" }

    private var points: [Point] {
        chart.series.enumerated().flatMap { seriesIndex, series in
            series.values.enumerated().map { index, value in
                Point(id: "\(seriesIndex)-\(index)", label: chart.labels[index], value: value,
                      series: series.name ?? "\(seriesIndex + 1)")
            }
        }
    }

    private var plot: some View {
        let single = chart.series.count == 1
        return Chart(points) { point in
            mark(point, single: single)
        }
        .chartLegend(single ? .hidden : .visible)
        .chartYAxisLabel {
            if let unit = chart.unit {
                Text(verbatim: unit)
            }
        }
    }

    @ChartContentBuilder
    private func mark(_ point: Point, single: Bool) -> some ChartContent {
        switch chart.kind {
        case .bar, .pie:
            bar(point, single: single)
        case .area:
            area(point, single: single)
        default:
            line(point, single: single)
        }
    }

    @ChartContentBuilder
    private func bar(_ point: Point, single: Bool) -> some ChartContent {
        let base = BarMark(x: .value(Self.labelName, point.label), y: .value(valueName, point.value))
        if single {
            base.foregroundStyle(Color.conduitAccent).cornerRadius(4)
        } else {
            base.foregroundStyle(by: .value(Self.seriesName, point.series))
                .position(by: .value(Self.seriesName, point.series))
                .cornerRadius(4)
        }
    }

    @ChartContentBuilder
    private func area(_ point: Point, single: Bool) -> some ChartContent {
        let base = AreaMark(x: .value(Self.labelName, point.label), y: .value(valueName, point.value))
            .interpolationMethod(.catmullRom)
        if single {
            base.foregroundStyle(Color.conduitAccent.opacity(0.35))
        } else {
            base.foregroundStyle(by: .value(Self.seriesName, point.series))
        }
    }

    @ChartContentBuilder
    private func line(_ point: Point, single: Bool) -> some ChartContent {
        let base = LineMark(x: .value(Self.labelName, point.label), y: .value(valueName, point.value))
            .interpolationMethod(.catmullRom)
        if single {
            base.foregroundStyle(Color.conduitAccent).symbol(.circle)
        } else {
            base.foregroundStyle(by: .value(Self.seriesName, point.series))
                .symbol(by: .value(Self.seriesName, point.series))
        }
    }

    private var pie: some View {
        let values = chart.series.first?.values ?? []
        let total = values.reduce(0, +)
        return HStack(alignment: .center, spacing: 16) {
            Chart(Array(values.enumerated()), id: \.offset) { index, value in
                SectorMark(angle: .value(valueName, value), innerRadius: .ratio(0.58), angularInset: 1.5)
                    .foregroundStyle(Self.palette[index % Self.palette.count])
                    .cornerRadius(3)
            }
            .frame(width: pieSize, height: pieSize)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(zip(chart.labels, values).enumerated()), id: \.offset) { index, slice in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Self.palette[index % Self.palette.count])
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(verbatim: slice.0)
                            .font(.caption)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Text(verbatim: (slice.1 / total).formatted(.percent.precision(.fractionLength(0)).locale(AppLocalization.formattingLocale)))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: sliceSummary(slice.0, slice.1, total: total)))
                }
            }
        }
    }

    /// A slice's label, value and share, for VoiceOver.
    private func sliceSummary(_ label: String, _ value: Double, total: Double) -> String {
        let locale = AppLocalization.formattingLocale
        let unit = chart.unit.map { " \($0)" } ?? ""
        let share = (value / total).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        return "\(label) \(value.formatted(.number.locale(locale)))\(unit), \(share)"
    }

    /// The slices' colours, which the legend's dots match.
    private static let palette: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .yellow, .pink, .indigo, .mint, .brown, .cyan]
}

// MARK: - Weather

struct RichWeatherCard: View {
    let card: RichCard

    var body: some View {
        if let weather = card.weather {
            RichInfoCardFrame(title: card.title, source: card.source) {
                VStack(alignment: .leading, spacing: 14) {
                    if let now = weather.now {
                        RichWeatherNow(now: now, place: weather.place, unit: weather.unit)
                    } else if let place = weather.place {
                        Text(verbatim: place)
                            .font(.subheadline.weight(.semibold))
                    }
                    if !weather.hours.isEmpty {
                        RichWeatherHours(hours: weather.hours)
                    }
                    if !weather.days.isEmpty {
                        RichWeatherDays(days: weather.days, unit: weather.unit)
                    }
                }
            }
        }
    }
}

extension RichWeather.Condition {
    var symbol: String {
        switch self {
        case .clear: "sun.max.fill"
        case .partlyCloudy: "cloud.sun.fill"
        case .cloudy: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .rain: "cloud.rain.fill"
        case .heavyRain: "cloud.heavyrain.fill"
        case .thunderstorm: "cloud.bolt.rain.fill"
        case .snow: "cloud.snow.fill"
        case .sleet: "cloud.sleet.fill"
        case .wind: "wind"
        }
    }

    var name: Text {
        switch self {
        case .clear: Text("Clear skies")
        case .partlyCloudy: Text("Partly cloudy")
        case .cloudy: Text("Cloudy")
        case .fog: Text("Fog")
        case .drizzle: Text("Drizzle")
        case .rain: Text("Rain")
        case .heavyRain: Text("Heavy rain")
        case .thunderstorm: Text("Thunderstorms")
        case .snow: Text("Snow")
        case .sleet: Text("Sleet")
        case .wind: Text("Windy")
        }
    }
}

private func richDegrees(_ value: Double) -> String {
    "\(Int(value.rounded()))°"
}

private func richPercent(_ percent: Int) -> String {
    (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)).locale(AppLocalization.formattingLocale))
}

private struct RichWeatherSymbol: View {
    let condition: RichWeather.Condition?

    var body: some View {
        Image(systemName: condition?.symbol ?? "thermometer.medium")
            .symbolRenderingMode(.multicolor)
            .accessibilityHidden(true)
    }
}

private struct RichWeatherNow: View {
    let now: RichWeather.Now
    let place: String?
    let unit: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RichWeatherSymbol(condition: now.condition)
                .font(.largeTitle)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                if let place {
                    Text(verbatim: place)
                        .font(.subheadline.weight(.semibold))
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: richDegrees(now.temp) + unit)
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                    now.condition.name
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let text = now.text {
                    Text(verbatim: text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RichWeatherPrecip: View {
    let precip: Int?

    var body: some View {
        if let precip, precip > 0 {
            HStack(spacing: 1) {
                Image(systemName: "drop.fill")
                    .accessibilityHidden(true)
                Text(verbatim: "\(precip)%")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.cyan)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Chance of rain or snow: \(richPercent(precip))"))
        }
    }
}

private struct RichWeatherHours: View {
    let hours: [RichWeather.Hour]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(Array(hours.enumerated()), id: \.offset) { _, hour in
                    VStack(spacing: 6) {
                        Text(verbatim: hour.time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        RichWeatherSymbol(condition: hour.condition)
                            .font(.title3)
                            .frame(height: 24)
                        Text(verbatim: richDegrees(hour.temp))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        RichWeatherPrecip(precip: hour.precip)
                    }
                    .frame(minWidth: 40)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct RichWeatherDays: View {
    let days: [RichWeather.Day]
    let unit: String

    @ScaledMetric(relativeTo: .subheadline) private var dayWidth: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var symbolWidth: CGFloat = 26
    @ScaledMetric(relativeTo: .caption2) private var precipWidth: CGFloat = 40
    @ScaledMetric(relativeTo: .subheadline) private var tempWidth: CGFloat = 36

    var body: some View {
        let low = days.map(\.low).min() ?? 0
        let high = days.map(\.high).max() ?? 0
        VStack(spacing: 8) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                HStack(spacing: 10) {
                    Text(verbatim: day.day)
                        .font(.subheadline)
                        .frame(width: dayWidth, alignment: .leading)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    RichWeatherSymbol(condition: day.condition)
                        .font(.body)
                        .frame(width: symbolWidth)
                    RichWeatherPrecip(precip: day.precip)
                        .frame(width: precipWidth, alignment: .leading)
                    Text(verbatim: richDegrees(day.low))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: tempWidth, alignment: .trailing)
                    RichTemperatureBar(low: day.low, high: day.high, rangeLow: low, rangeHigh: high)
                        .frame(height: 5)
                        .accessibilityHidden(true)
                    Text(verbatim: richDegrees(day.high))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .frame(width: tempWidth, alignment: .leading)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(dayLabel(day))
            }
        }
    }

    private func dayLabel(_ day: RichWeather.Day) -> Text {
        var label = Text(verbatim: "\(day.day), ")
        if let condition = day.condition {
            label = label + condition.name + Text(verbatim: ", ")
        }
        label = label + Text("Low \(richDegrees(day.low) + unit), high \(richDegrees(day.high) + unit)")
        if let precip = day.precip, precip > 0 {
            label = label + Text(verbatim: ", ") + Text("Chance of rain or snow: \(richPercent(precip))")
        }
        return label
    }
}

/// A day's low to high, placed within the week's.
private struct RichTemperatureBar: View {
    let low: Double
    let high: Double
    let rangeLow: Double
    let rangeHigh: Double

    var body: some View {
        GeometryReader { geometry in
            let span = max(rangeHigh - rangeLow, 1)
            let start = (low - rangeLow) / span * geometry.size.width
            let width = max((high - low) / span * geometry.size.width, geometry.size.height)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(LinearGradient(colors: [.cyan, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width)
                    .offset(x: min(start, geometry.size.width - width))
            }
        }
    }
}

// MARK: - Comparison

struct RichComparisonCard: View {
    let card: RichCard

    @ScaledMetric(relativeTo: .subheadline) private var columnWidth: CGFloat = 200

    var body: some View {
        RichInfoCardFrame(title: card.title, source: card.source) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(card.options.enumerated()), id: \.offset) { _, option in
                        RichOptionColumn(option: option)
                            .frame(width: card.options.count == 2 ? columnWidth : columnWidth * 1.1, alignment: .topLeading)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct RichOptionColumn: View {
    let option: RichOption

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if option.recommended {
                Label {
                    Text("Recommended")
                } icon: {
                    Image(systemName: "star.fill")
                }
                .font(.caption2.weight(.bold))
                .labelStyle(RichCompactLabelStyle())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                // The sent-bubble fill: the dark-mode accent is too light
                // under white text.
                .background(Color.conduitUserBubble, in: Capsule())
            }
            Text(verbatim: option.name)
                .font(.subheadline.weight(.semibold))
            if let summary = option.summary {
                Text(verbatim: summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !option.facts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(option.facts.enumerated()), id: \.offset) { _, fact in
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: fact.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 6)
                            Text(verbatim: fact.value)
                                .font(.caption.weight(.semibold))
                                .multilineTextAlignment(.trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            ForEach(Array(option.pros.enumerated()), id: \.offset) { _, pro in
                RichProCon(text: pro, isPro: true)
            }
            ForEach(Array(option.cons.enumerated()), id: \.offset) { _, con in
                RichProCon(text: con, isPro: false)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if option.recommended {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.conduitAccent, lineWidth: 1.5)
            }
        }
    }
}

private struct RichProCon: View {
    let text: String
    let isPro: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: isPro ? "plus.circle.fill" : "minus.circle.fill")
                .font(.caption)
                .foregroundStyle(isPro ? Color.green : Color.orange)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.caption)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPro ? Text("Pro: \(text)") : Text("Con: \(text)"))
    }
}

// MARK: - Steps

struct RichStepsCard: View {
    let card: RichCard

    var body: some View {
        RichInfoCardFrame(title: card.title, source: card.source) {
            VStack(alignment: .leading, spacing: 12) {
                if !card.needs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("You'll need")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(Array(card.needs.enumerated()), id: \.offset) { _, need in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(verbatim: "•")
                                    .foregroundStyle(Color.conduitAccent)
                                    .accessibilityHidden(true)
                                Text(verbatim: need)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                ForEach(Array(card.steps.enumerated()), id: \.offset) { index, step in
                    RichStepRow(number: index + 1, step: step, key: key, title: card.title)
                }
                if memory.notificationsOff, card.steps.contains(where: { $0.timer != nil }) {
                    Text("Notifications are off for Conduit in iPhone Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ObservedObject private var memory = RichStepsMemory.shared

    private var key: String { RichStepsMemory.key(for: card) }
}

private struct RichStepRow: View {
    let number: Int
    let step: RichStep
    let key: String
    let title: String?

    @ObservedObject private var memory = RichStepsMemory.shared

    var body: some View {
        let done = memory.isDone(key, number)
        HStack(alignment: .top, spacing: 10) {
            Button {
                memory.toggle(key, number)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(done ? Color.conduitAccent : Color.secondary)
                        .accessibilityHidden(true)
                    Text(verbatim: "\(number). \(step.text)")
                        .font(.subheadline)
                        .strikethrough(done)
                        .foregroundStyle(done ? Color.secondary : Color.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(done ? Text("Done") : Text(verbatim: ""))
            if let seconds = step.timer {
                RichStepTimer(seconds: seconds, key: key, number: number, text: step.text, title: title)
            }
        }
    }
}

private struct RichStepTimer: View {
    let seconds: Int
    let key: String
    let number: Int
    let text: String
    let title: String?

    @ObservedObject private var memory = RichStepsMemory.shared

    var body: some View {
        if let end = memory.timerEnd(key, number) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = end.timeIntervalSince(context.date)
                // Done shows for a while; after that it's ready to start again.
                chip(left: left > -RichStepsMemory.doneShown ? left : nil)
            }
        } else {
            chip(left: nil)
        }
    }

    /// The timer's button: running or Done while `left` is set, ready to
    /// start otherwise.
    private func chip(left: TimeInterval?) -> some View {
        Button {
            if left != nil {
                memory.stopTimer(key, number)
            } else {
                memory.startTimer(key, number, seconds: seconds, text: text, title: title)
            }
        } label: {
            Group {
                if let left, left > 0 {
                    Label {
                        Text(verbatim: Self.clock(left))
                    } icon: {
                        Image(systemName: "stop.fill")
                    }
                } else if left != nil {
                    Label {
                        Text("Done")
                    } icon: {
                        Image(systemName: "bell.fill")
                    }
                } else {
                    Label {
                        Text(verbatim: Self.clock(TimeInterval(seconds)))
                    } icon: {
                        Image(systemName: "timer")
                    }
                }
            }
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .labelStyle(RichCompactLabelStyle())
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(left != nil ? Color.white : Color.conduitAccent)
            // Running: white on the sent-bubble fill, which keeps 4.5:1 in
            // dark mode where the accent itself is too light.
            .background(left != nil ? Color.conduitUserBubble : Color.conduitAccent.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(left != nil ? Text("Stop timer") : Text("Start a \(Self.spoken(seconds)) timer"))
        .accessibilityValue(left.map { $0 > 0 ? Text(verbatim: Self.clock($0)) : Text("Done") } ?? Text(verbatim: ""))
    }

    /// Like 6:30, or 1:05:00.
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(Int(interval.rounded(.up)), 0)
        let hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }

    /// Like 6 minutes, 30 seconds, in the app's language.
    static func spoken(_ seconds: Int) -> String {
        spokenFormatter.calendar?.locale = AppLocalization.formattingLocale
        return spokenFormatter.string(from: TimeInterval(seconds)) ?? "\(seconds)"
    }

    private static let spokenFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.calendar = Calendar.current
        return formatter
    }()
}

/// Which steps the user ticked off and the timers they started, both kept
/// across launches, with a notification for when a timer ends while
/// Conduit isn't on screen.
@MainActor
final class RichStepsMemory: ObservableObject {
    static let shared = RichStepsMemory()

    nonisolated static let notificationPrefix = "rich-step-timer-"
    private static let defaultsKey = "richCards.stepsDone"
    private static let timersKey = "richCards.stepTimers"
    /// How long a finished timer still shows Done.
    static let doneShown: TimeInterval = 10 * 60
    /// Cards whose ticks are kept; the oldest go first.
    private static let keptCards = 200

    private struct Ticks: Codable {
        var done: Set<Int>
        var at: Date
    }

    @Published private var ticks: [String: Ticks]
    @Published private var timers: [String: Date]
    /// Set when a timer started without permission to notify.
    @Published private(set) var notificationsOff = false
    private let defaults: UserDefaults
    private let notifier: Notifier
    /// Each timer's last scheduling task, so a later start's request lands after an earlier one's.
    /// Dropped when it finishes; the token tells it apart from a newer start's.
    private(set) var scheduling: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    /// Asks to notify and schedules the timer's notification.
    struct Notifier {
        var allowed: @MainActor () async -> Bool
        var add: @MainActor (UNNotificationRequest) async throws -> Void
        var remove: @MainActor ([String]) -> Void

        static let system = Notifier(
            allowed: {
                let center = UNUserNotificationCenter.current()
                switch await center.notificationSettings().authorizationStatus {
                case .notDetermined:
                    return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                case .authorized, .provisional, .ephemeral:
                    return true
                default:
                    return false
                }
            },
            add: { try await UNUserNotificationCenter.current().add($0) },
            remove: { RichStepsMemory.clearNotifications($0) })
    }

    init(defaults: UserDefaults = .standard, notifier: Notifier = .system) {
        self.defaults = defaults
        self.notifier = notifier
        ticks = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([String: Ticks].self, from: $0) } ?? [:]
        let timers = defaults.data(forKey: Self.timersKey).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        self.timers = timers.filter { $0.value.addingTimeInterval(Self.doneShown) > .now }
        Self.clearNotifications(Array(Set(timers.keys).subtracting(self.timers.keys)))
    }

    /// The same steps get the same key, whichever chat or call shows them.
    static func key(for card: RichCard) -> String {
        let steps = card.steps.map { step in step.timer.map { "\(step.text)\u{1D}\($0)" } ?? step.text }
        let text = ([card.title ?? ""] + card.needs + ["\u{1E}"] + steps).joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func isDone(_ key: String, _ number: Int) -> Bool {
        ticks[key]?.done.contains(number) ?? false
    }

    func toggle(_ key: String, _ number: Int) {
        var entry = ticks[key] ?? Ticks(done: [], at: .now)
        if entry.done.contains(number) {
            entry.done.remove(number)
        } else {
            entry.done.insert(number)
        }
        entry.at = .now
        ticks[key] = entry
        if ticks.count > Self.keptCards, let oldest = ticks.min(by: { $0.value.at < $1.value.at })?.key {
            ticks.removeValue(forKey: oldest)
        }
        if let data = try? JSONEncoder().encode(ticks) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// When the timer ends, while it runs or shows Done.
    func timerEnd(_ key: String, _ number: Int) -> Date? {
        timers[Self.timerID(key, number)].flatMap { $0.addingTimeInterval(Self.doneShown) > .now ? $0 : nil }
    }

    @discardableResult
    func startTimer(_ key: String, _ number: Int, seconds: Int, text: String, title: String?) -> Task<Void, Never> {
        let id = Self.timerID(key, number)
        let end = Date.now.addingTimeInterval(TimeInterval(seconds))
        timers[id] = end
        saveTimers()
        let content = UNMutableNotificationContent()
        content.title = title ?? AppLocalization.string("Timer done")
        content.body = text
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false))
        let earlier = scheduling[id]?.task
        let token = UUID()
        let task = Task { @MainActor in
            // Done: forget this task unless a newer start replaced it.
            defer { if scheduling[id]?.token == token { scheduling[id] = nil } }
            // The countdown runs on the card either way; without permission
            // the card says no notification will come.
            let allowed = await notifier.allowed()
            // An earlier start's request may still be going in under the same
            // identifier; let it finish first so this one is the one that stays.
            // Waited for even when this start is dropped, so a later start that
            // waits on this task also waits on that one.
            await earlier?.value
            // Stopped (or started again) meanwhile: this one isn't wanted.
            guard timers[id] == end else { return }
            notificationsOff = !allowed
            guard allowed else { return }
            do {
                try await notifier.add(request)
            } catch {
                // Only the start that is still current says so.
                if timers[id] == end { notificationsOff = true }
            }
            // Stopped or started again while it was being added: take it back.
            // A newer start waits for this task, so its own request goes in after.
            if timers[id] != end {
                notifier.remove([id])
            }
        }
        scheduling[id] = (token, task)
        return task
    }

    func stopTimer(_ key: String, _ number: Int) {
        let id = Self.timerID(key, number)
        timers.removeValue(forKey: id)
        saveTimers()
        notifier.remove([id])
    }

    private static func clearNotifications(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func saveTimers() {
        let kept = timers.filter { $0.value.addingTimeInterval(Self.doneShown) > .now }
        Self.clearNotifications(Array(Set(timers.keys).subtracting(kept.keys)))
        timers = kept
        if let data = try? JSONEncoder().encode(timers) {
            defaults.set(data, forKey: Self.timersKey)
        }
    }

    private static func timerID(_ key: String, _ number: Int) -> String {
        "\(notificationPrefix)\(key)-\(number)"
    }
}
