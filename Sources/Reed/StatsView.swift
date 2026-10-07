import Charts
import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

/// How much has been read and listened to: totals over a span of time, words by day or month, the sites and books read most, and what was read last.
struct StatsView: View {
    let library: Library
    @State private var span = Span.week

    enum Span: String, CaseIterable, Identifiable {
        case week = "Week", month = "Month", year = "Year", all = "All time"
        var id: Self { self }

        /// When it began, or nil for all time.
        func start(now: Date = .now, calendar: Calendar = .current) -> Date? {
            switch self {
            case .week: calendar.dateInterval(of: .weekOfYear, for: now)?.start
            case .month: calendar.dateInterval(of: .month, for: now)?.start
            case .year: calendar.dateInterval(of: .year, for: now)?.start
            case .all: nil
            }
        }

        /// The chart's bars: a week and a month by day, longer by month.
        var bars: (unit: Calendar.Component, count: Int) {
            switch self {
            case .week: (.day, 7)
            case .month: (.day, 30)
            case .year, .all: (.month, 12)
            }
        }
    }

    var body: some View {
        let records = library.readingRecords
        let totals = ReadingStats.totals(records, since: span.start())
        VStack(spacing: 0) {
            #if os(macOS)
            ColumnHeader(title: "Statistics", subtitle: subtitle(records)) {} below: { spanPicker }
            #endif
            List {
                #if os(iOS)
                spanPicker.listRowSeparator(.hidden)
                #endif
                tiles(totals).listRowSeparator(.hidden)
                chart(records).listRowSeparator(.hidden)
                let sources = ReadingStats.sources(records, limit: 5)
                if !sources.isEmpty {
                    Section {
                        ForEach(sources, id: \.name) { source in
                            HStack {
                                Text(source.name).lineLimit(1)
                                Spacer()
                                Text(Self.words(source.words)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.system(size: 13))
                        }
                    } header: { header("MOST READ") }
                }
                let recent = records.sorted { $0.lastReadAt > $1.lastReadAt }.prefix(15)
                if !recent.isEmpty {
                    Section {
                        ForEach(recent) { record in RecordRow(record: record) }
                    } header: { header("RECENTLY") }
                }
            }
            .listStyle(.plain)
            .overlay {
                if records.isEmpty {
                    Text("Nothing read yet.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
        .columnTitle("Statistics")
    }

    private func subtitle(_ records: [ReadingRecord]) -> String {
        let started = records.map(\.startedAt).min()
        return started.map { "Since \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Nothing read yet"
    }

    private var spanPicker: some View {
        Picker("Span", selection: $span) {
            ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
    }

    private func tiles(_ totals: ReadingStats.Totals) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
            GridRow {
                tile("Words read", Self.words(totals.readWords),
                     detail: totals.readWords >= 1 ? "About \(Self.duration(words: totals.readWords))" : nil)
                tile("Words heard", Self.words(totals.listenedWords), detail: nil)
            }
            GridRow {
                tile("Finished", totals.finished.formatted(), detail: nil)
            }
        }
        .padding(.vertical, 10)
    }

    private func tile(_ title: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1.2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, design: .serif)).monospacedDigit()
            Text(detail ?? " ").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chart(_ records: [ReadingRecord]) -> some View {
        let bars = span.bars
        let periods = ReadingStats.periods(records, by: bars.unit, count: bars.count)
        return Chart {
            ForEach(periods, id: \.start) { period in
                BarMark(x: .value("Day", period.start, unit: bars.unit), y: .value("Words", period.readWords))
                    .foregroundStyle(by: .value("Kind", "Read"))
                BarMark(x: .value("Day", period.start, unit: bars.unit), y: .value("Words", period.listenedWords))
                    .foregroundStyle(by: .value("Kind", "Heard"))
            }
        }
        .chartForegroundStyleScale(["Read": ReedStyle.accent, "Heard": ReedStyle.accent.opacity(0.4)])
        .chartXAxis {
            if bars.unit == .month {
                AxisMarks(values: .stride(by: .month, count: 2)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) }
            } else if bars.count > 7 {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) }
            } else {
                AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 160)
        .padding(.vertical, 8)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .medium)).tracking(1.7)
    }

    static func words(_ words: Double) -> String { Int(words.rounded()).formatted() }

    /// How long `words` take to read at the pace reading times are given in.
    static func duration(words: Double) -> String {
        let minutes = Int((words / 230).rounded())
        return minutes < 60 ? "\(max(minutes, 1)) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

private struct RecordRow: View {
    let record: ReadingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.title).font(.system(size: 13)).lineLimit(2)
            HStack(spacing: 4) {
                Text(record.source).lineLimit(1)
                Spacer(minLength: 6)
                if record.finishedAt != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Finished")
                } else {
                    Text("\(Int(max(record.furthestRead, record.furthestListened) * 100))%").monospacedDigit()
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
