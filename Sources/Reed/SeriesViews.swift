import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

/// A series in the article list: what's up next, and how far through its parts reading has got.
struct SeriesRow: View {
    let series: Series
    let parts: [Article]
    @Binding var expanded: Bool

    /// The part to carry on with: the first one not finished.
    static func upNext(in parts: [Article]) -> Article? { parts.first { !$0.isRead } }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 4) {
                Text((parts.first?.domain ?? "").lowercased()).font(.system(size: 9, weight: .semibold)).tracking(1.1)
                Spacer()
                Button { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack").font(.system(size: 9))
                        Text("\(parts.count) parts").font(.system(size: 9, weight: .semibold)).tracking(1.1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(.vertical, 4).padding(.leading, 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide parts" : "Show parts")
            }
            .foregroundStyle(ReedStyle.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(series.name).font(.system(size: 18, weight: .medium, design: .serif)).lineLimit(3).lineSpacing(2)
                if let author = parts.lazy.compactMap(\.author).first(where: { !$0.isEmpty }) {
                    Text(author).font(.system(size: 12, design: .serif).italic()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let next = Self.upNext(in: parts), !expanded {
                (Text("Up next  ").foregroundStyle(.secondary) + Text(next.title).font(.system(size: 12, design: .serif)))
                    .font(.system(size: 11)).lineLimit(2)
            }
            HStack(spacing: 3) {
                ForEach(parts) { part in
                    Rectangle().fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(ReedStyle.accent).scaleEffect(x: part.isRead ? 1 : part.progress, anchor: .leading)
                        }
                        .frame(height: 3).clipShape(Capsule())
                }
            }
            .padding(.top, 2)
            .accessibilityHidden(true)
            HStack(spacing: 5) {
                if parts.contains(where: { $0.state == .downloading || $0.state == .queued }) { ProgressView().controlSize(.mini) }
                Text(progress)
                Spacer()
                if let saved = parts.map(\.savedAt).max() {
                    Text("Saved \(saved.formatted(.dateTime.month(.abbreviated).day()))")
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 2)
        }
        .padding(.vertical, 15).padding(.horizontal, 7)
        .accessibilityElement(children: .combine)
    }

    private var progress: String {
        let read = parts.filter(\.isRead).count
        guard read < parts.count else { return "Caught up" }
        let minutes = parts.filter { !$0.isRead }.reduce(0) { $0 + Double($1.readingMinutes) * (1 - $1.progress) }
        let left = Duration.seconds(max(1, minutes.rounded()) * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "\(read) of \(parts.count) read · \(left) left"
    }
}

/// One part of a shown series, under its series.
struct PartRow: View {
    let article: Article
    let number: Int
    let seriesName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary).frame(minWidth: 14, alignment: .trailing)
            Text(title).font(.system(size: 14, design: .serif)).lineLimit(2)
                .foregroundStyle(article.isRead ? .secondary : .primary)
            Spacer(minLength: 6)
            Group {
                if article.state.isReadable {
                    ReadingStatus(isRead: article.isRead, progress: article.progress, minutes: article.readingMinutes)
                } else {
                    Text(article.state.label)
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 7).padding(.leading, 12).padding(.trailing, 7)
        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 1) }
        .padding(.leading, 9)
        .accessibilityElement(children: .combine)
    }

    /// The title without the series' name it starts with, as in "Part 3: Parsing" for "Lox, part 3: Parsing".
    private var title: String {
        guard !seriesName.isEmpty, let range = article.title.range(of: seriesName, options: [.anchored, .caseInsensitive]) else {
            return article.title
        }
        let rest = article.title[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ":-–—|,·").union(.whitespaces))
        guard let first = rest.first else { return article.title }
        return first.uppercased() + rest.dropFirst()
    }
}

/// Chooses the parts of a new series from the articles saved from the same site.
struct MakeSeriesView: View {
    let library: Library
    let start: Article
    var onMake: (Series) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UUID>
    @State private var name = ""
    /// Whether the name was typed, rather than made up from the chosen titles.
    @State private var named = false

    init(library: Library, start: Article, onMake: @escaping (Series) -> Void) {
        self.library = library
        self.start = start
        self.onMake = onMake
        _chosen = State(initialValue: [start.id])
    }

    private var candidates: [Article] {
        library.articles
            .filter { $0.id == start.id || ($0.domain == start.domain && library.series(of: $0) == nil) }
            .sorted { ($0.publishedAt ?? $0.savedAt) < ($1.publishedAt ?? $1.savedAt) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SheetHeading(symbol: "square.stack", title: "Make a series.",
                         detail: "Choose its parts from the articles saved from \(start.domain). They're put in order by the part numbers in their titles, or else by date, and can be reordered later.")
            TextField("Name", text: Binding(get: { name }, set: { name = $0; named = true }), prompt: Text("Series name"))
                .warmField()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(candidates) { article in
                        Button { toggle(article) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: chosen.contains(article.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(article.id) ? ReedStyle.accent : .secondary)
                                Text(article.title).font(.system(size: 14, design: .serif)).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Text("\(chosen.count) \(chosen.count == 1 ? "part" : "parts")").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Make Series", action: make).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheetLayout()
        .onChange(of: chosen, initial: true) {
            if !named { name = SeriesTitle.name(for: candidates.filter { chosen.contains($0.id) }.map(\.title)) }
        }
    }

    private func toggle(_ article: Article) {
        if chosen.contains(article.id) { chosen.remove(article.id) } else { chosen.insert(article.id) }
    }

    private func make() {
        let parts = candidates.filter { chosen.contains($0.id) }
        if let series = library.makeSeries(named: name, of: parts) { onMake(series) }
        dismiss()
    }
}

/// Finds the other chapters of a serial from one of them, and saves those chosen as a series.
struct FindChaptersView: View {
    let library: Library
    let start: Article
    @Environment(\.dismiss) private var dismiss
    @State private var chapters: [Chapter] = []
    @State private var searching = true
    @State private var chosen: Set<URL> = []
    @State private var name = ""
    @State private var error: String?

    private func isSaved(_ chapter: Chapter) -> Bool { library.article(at: chapter.url) != nil }
    private var unsaved: [Chapter] { chapters.filter { !isSaved($0) } }
    /// The chapters that will make up the series: those saved already, and those chosen.
    private var parts: [Chapter] { chapters.filter { isSaved($0) || chosen.contains($0.url) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SheetHeading(symbol: "square.stack", title: "Other chapters.", detail: summary)
            if !searching && chapters.count > 1 {
                TextField("Name", text: $name, prompt: Text("Series name")).warmField()
            }
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(chapters) { chapter in row(chapter).id(chapter.url) }
                    }
                }
                .frame(maxHeight: 320)
                .onChange(of: chapters.count) { if searching, let last = chapters.last { scroller.scrollTo(last.url) } }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if searching {
                    ProgressView().controlSize(.small)
                } else if !unsaved.isEmpty {
                    Button(chosen.count == unsaved.count ? "Choose None" : "Choose All") {
                        chosen = chosen.count == unsaved.count ? [] : Set(unsaved.map(\.url))
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(ReedStyle.accent)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Make Series" : "Save \(chosen.count)", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(searching || parts.count < 2 || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheetLayout()
        .task { await find() }
    }

    private var summary: String {
        let site = start.domain
        if searching { return chapters.count > 1 ? "Found \(chapters.count) chapters on \(site) so far…" : "Looking for the chapters around this one on \(site)…" }
        if chapters.count < 2 { return "No other chapters were found on \(site)." }
        return "Found \(chapters.count) chapters on \(site). Those chosen are saved, and all are gathered into a series in this order."
    }

    private func row(_ chapter: Chapter) -> some View {
        let saved = isSaved(chapter)
        let picked = saved || chosen.contains(chapter.url)
        return Button { if chosen.remove(chapter.url) == nil { chosen.insert(chapter.url) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(saved ? Color.secondary : picked ? ReedStyle.accent : .secondary)
                Text(chapter.title.isEmpty ? chapter.url.lastPathComponent : chapter.title)
                    .font(.system(size: 14, design: .serif)).multilineTextAlignment(.leading)
                    .foregroundStyle(saved ? .secondary : .primary)
                Spacer(minLength: 0)
                if saved { Text("Saved").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saved || searching)
    }

    private func find() async {
        do {
            let search = try await library.findChapters(around: start) { chapters = $0 }
            chapters = search.chapters
            chosen = Set(unsaved.map(\.url))
            name = library.series(of: start)?.name ?? search.name
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        searching = false
    }

    private func save() {
        do { try library.save(parts, asSeriesNamed: name); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
