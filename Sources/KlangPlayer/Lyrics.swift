import SwiftUI

/// Song lyrics from LRCLIB (lrclib.net): free, no key, often with timings for each line.
struct Lyrics: Equatable {
    struct Line: Equatable, Identifiable {
        let id: Int
        let time: Double
        let text: String
    }
    let lines: [Line]        // timed lines; empty when only plain text is known
    let plain: String?
    var isSynced: Bool { !lines.isEmpty }

    /// Parses LRC: "[mm:ss.xx] text", several time tags per line allowed.
    static func parseLRC(_ s: String) -> [Line] {
        var out: [(Double, String)] = []
        let tag = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        for raw in s.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let tags = tag.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = tags.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in tags {
                let t = (Double(ns.substring(with: m.range(at: 1))) ?? 0) * 60 + (Double(ns.substring(with: m.range(at: 2))) ?? 0)
                out.append((t, text))
            }
        }
        return out.sorted { $0.0 < $1.0 }.enumerated().map { Line(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    /// Index of the line being sung at `position`.
    func current(at position: Double) -> Int? {
        lines.lastIndex { $0.time <= position + 0.3 }
    }
}

@MainActor
final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()
    private var cache: [String: Lyrics?] = [:]
    /// Track id → lyrics found (true) or not (false); missing = not checked yet.
    @Published private(set) var known: [String: Bool] = [:]
    /// Track id → timed lyrics.
    @Published private(set) var synced: Set<String> = []

    func lyrics(for t: Track) async -> Lyrics? {
        if let c = cache[t.Id] { return c }
        let found = await fetch(t)
        cache[t.Id] = found
        known[t.Id] = found != nil
        if found?.isSynced == true { synced.insert(t.Id) }
        return found
    }

    /// Checks a list of tracks (an album) a few at a time, for the lyrics marks.
    func check(_ tracks: [Track]) async {
        let todo = tracks.filter { known[$0.Id] == nil }
        for chunk in stride(from: 0, to: todo.count, by: 3).map({ Array(todo[$0..<min($0 + 3, todo.count)]) }) {
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { g in
                for t in chunk { g.addTask { _ = await self.lyrics(for: t) } }
            }
        }
    }

    private func fetch(_ t: Track) async -> Lyrics? {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [.init(name: "artist_name", value: t.artist), .init(name: "track_name", value: t.Name)]
        if let a = t.Album, !a.isEmpty { c.queryItems?.append(.init(name: "album_name", value: a)) }
        if t.duration > 0 { c.queryItems?.append(.init(name: "duration", value: "\(Int(t.duration.rounded()))")) }
        if let l = await get(c.url!).flatMap(Self.lyrics(from:)) { return l }
        // No exact match (album or duration differ): search, prefer a close duration.
        var s = URLComponents(string: "https://lrclib.net/api/search")!
        s.queryItems = [.init(name: "artist_name", value: t.artist), .init(name: "track_name", value: t.Name)]
        guard let data = await get(s.url!),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let ranked = list.sorted {
            abs(($0["duration"] as? Double ?? 0) - t.duration) < abs(($1["duration"] as? Double ?? 0) - t.duration)
        }
        for item in ranked.prefix(5) where abs((item["duration"] as? Double ?? t.duration) - t.duration) < 10 {
            if let l = Self.lyrics(from: item) { return l }
        }
        return nil
    }

    private func get(_ url: URL) async -> Data? {
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.setValue("KlangPlayer (https://github.com/satsura/klang-player)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func lyrics(from data: Data) -> Lyrics? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { lyrics(from: $0) }
    }

    private static func lyrics(from o: [String: Any]) -> Lyrics? {
        if o["instrumental"] as? Bool == true { return Lyrics(lines: [], plain: String(localized: "Instrumental")) }
        let synced = (o["syncedLyrics"] as? String).map(Lyrics.parseLRC) ?? []
        let plain = (o["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !synced.isEmpty || !(plain ?? "").isEmpty else { return nil }
        return Lyrics(lines: synced, plain: plain)
    }
}

/// Lyrics of the current track; timed lyrics follow the song, a click on a line seeks to it.
struct LyricsView: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var clock = Player.shared.clock
    let close: () -> Void
    @State private var lyrics: Lyrics?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(title: String(localized: "Lyrics"), back: close)
            Group {
                if loading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let l = lyrics, l.isSynced {
                    synced(l)
                } else if let text = lyrics?.plain {
                    ScrollView {
                        Text(text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                } else {
                    EmptyState(icon: "text.quote", text: String(localized: player.current == nil ? "Nothing playing" : "No lyrics found"))
                }
            }
            .frame(maxHeight: .infinity)
            Text("Lyrics: lrclib.net").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.bottom, 4)
        }
        .task(id: player.current?.Id) {
            guard let t = player.current else { lyrics = nil; return }
            loading = true
            lyrics = await LyricsStore.shared.lyrics(for: t)
            loading = false
        }
    }

    private func synced(_ l: Lyrics) -> some View {
        let cur = l.current(at: clock.position)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(l.lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 15, weight: line.id == cur ? .bold : .semibold))
                            .foregroundStyle(line.id == cur ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(to: line.time) }
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 120)
            }
            .onChange(of: cur) {
                guard let cur else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(cur, anchor: UnitPoint(x: 0, y: 0.35)) }
            }
            .onAppear { if let cur { proxy.scrollTo(cur, anchor: UnitPoint(x: 0, y: 0.35)) } }
        }
    }
}
