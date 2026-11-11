import SwiftUI

/// A queue from a short description ("calm for work", "Russian 90s", "forgotten favorites"):
/// matches words to Last.fm artist tags, decades, language and listening history of the library.
/// Runs locally; Apple's on-device model doesn't support Russian, so this is rule-based.
@MainActor
enum SmartMix {
    struct Query: Equatable {
        var tags: Set<String> = []
        var years: ClosedRange<Int>?
        var russian: Bool?
        var favorites = false
        var forgotten = false
        var isEmpty: Bool { tags.isEmpty && years == nil && russian == nil && !favorites && !forgotten }
    }

    private static let moods: [(words: [String], tags: [String])] = [
        (["спокойн", "тих", "расслаб", "релакс", "для работы", "фон", "мягк", "calm", "relax", "chill", "work", "focus", "mellow"],
         ["chillout", "chill", "ambient", "downtempo", "acoustic", "mellow", "lounge", "trip-hop", "relaxing", "calm",
          "singer-songwriter", "dream pop", "easy listening", "instrumental"]),
        (["энерг", "бодр", "драйв", "спорт", "громк", "вечерин", "energetic", "upbeat", "drive", "workout", "party"],
         ["rock", "alternative rock", "hard rock", "punk", "metal", "rap metal", "nu metal", "dance", "big beat", "funk",
          "energetic", "upbeat", "indie rock"]),
        (["грустн", "печал", "меланх", "мрачн", "sad", "melanch", "dark"],
         ["sad", "melancholic", "melancholy", "dark", "atmospheric", "dark ambient", "slowcore"]),
        (["джаз", "jazz"], ["jazz", "nu jazz", "acid jazz", "smooth jazz", "jazz hop", "doom jazz", "dark jazz"]),
        (["электрон", "electro", "techno", "house", "idm"],
         ["electronic", "electronica", "idm", "techno", "house", "synthpop", "trip-hop", "downtempo"]),
        (["рок", "rock"], ["rock", "alternative rock", "indie rock", "russian rock", "post-rock", "hard rock"]),
        (["поп", "pop"], ["pop", "indie pop", "synthpop", "dream pop"]),
        (["женск", "female"], ["female vocalists", "female vocalist"]),
        (["инструмент", "без слов", "instrumental"],
         ["instrumental", "post-rock", "ambient", "soundtrack", "classical", "modern classical", "neoclassical"]),
        (["романт", "любов", "romantic", "love"], ["romantic", "love", "soul", "rnb", "ballad"]),
        (["фолк", "акуст", "folk", "acoustic"], ["folk", "acoustic", "singer-songwriter", "indie folk"]),
    ]

    static func parse(_ text: String) -> Query {
        let s = text.lowercased()
        var q = Query()
        for m in moods where m.words.contains(where: s.contains) { q.tags.formUnion(m.tags) }
        if ["русск", "на русском", "russian", "отечеств"].contains(where: s.contains) { q.russian = true }
        if ["иностран", "зарубеж", "english", "на английском"].contains(where: s.contains) { q.russian = false }
        if ["любим", "избран", "favorite", "loved"].contains(where: s.contains) { q.favorites = true }
        if ["давно не", "забыт", "не слушал", "forgotten"].contains(where: s.contains) { q.forgotten = true }
        // Decades: "90-е", "90-х", "90s", "девяностые", "нулевые", "2000-е", a year.
        let decades: [(String, Int)] = [("девяност", 1990), ("восьмидес", 1980), ("семидес", 1970), ("нулев", 2000), ("десятые", 2010)]
        for (w, y) in decades where s.contains(w) { q.years = y...(y + 9) }
        if let r = s.range(of: #"(19|20)?(\d0)\s*-?\s*(е|х|s|ые|ых)\b"#, options: .regularExpression) {
            let digits = s[r].filter(\.isNumber)
            if let n = Int(digits) {
                let y = n >= 1000 ? n : (n >= 30 ? 1900 + n : 2000 + n)
                q.years = y...(y + 9)
            }
        } else if let r = s.range(of: #"\b(19|20)\d\d\b"#, options: .regularExpression), let y = Int(s[r]) {
            q.years = y...y
        }
        if ["новое", "свеж", "recent", "new"].contains(where: s.contains) {
            let y = Calendar.current.component(.year, from: Date())
            q.years = (y - 4)...y
        }
        // Any other word may be a tag itself ("trip-hop", "shoegaze").
        if q.isEmpty {
            for w in s.split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init) where w.count >= 4 { q.tags.insert(w) }
        }
        return q
    }

    /// Builds the queue (about 40 tracks from up to 12 albums). `progress` reports tag loading.
    static func build(_ text: String, progress: @escaping (String) -> Void) async -> [Track] {
        let q = parse(text)
        let lib = Library.shared
        if lib.albums.isEmpty { await lib.load() }
        if q.favorites || q.forgotten { await lib.loadHome() }
        let tags = q.tags.isEmpty ? [:] : await artistTags(progress: progress)

        let favAlbums = Set(lib.favoriteAlbums.map(\.Id) + lib.favoriteTracks.compactMap(\.AlbumId))
        let recent = Set(lib.recentPlayedAlbums.map(\.Id))
        func isRussian(_ s: String) -> Bool { s.range(of: "[а-яё]", options: [.regularExpression, .caseInsensitive]) != nil }

        var scored: [(Album, Double)] = []
        for a in lib.albums where a.parts == nil {
            if let y = q.years, !(a.ProductionYear.map { y.contains($0) } ?? false) { continue }
            let artistTags = tags[Library.artistKey(a.artist)] ?? []
            if let ru = q.russian {
                let russian = isRussian(a.artist) || isRussian(a.Name) || artistTags.contains { $0.contains("russian") }
                if russian != ru { continue }
            }
            if q.favorites, !favAlbums.contains(a.Id) { continue }
            if q.forgotten, recent.contains(a.Id) { continue }
            var score = 1.0
            if !q.tags.isEmpty {
                // Earlier tags of an artist describe it better.
                let hits = artistTags.enumerated().filter { t in q.tags.contains { t.element == $0 || t.element.contains($0) } }
                guard !hits.isEmpty else { continue }
                score = hits.reduce(0) { $0 + 1 / Double($1.offset + 1) }
            }
            scored.append((a, score + Double.random(in: 0..<0.3)))
        }
        var out: [Track] = []
        for (a, _) in scored.sorted(by: { $0.1 > $1.1 }).prefix(12) {
            if let t = try? await lib.tracks(for: a) { out += t.shuffled().prefix(4) }
        }
        return out.shuffled()
    }

    /// Last.fm top tags of every library artist, cached on disk for 30 days.
    static func artistTags(progress: (String) -> Void) async -> [String: [String]] {
        let d = UserDefaults.standard
        var cache = d.dictionary(forKey: "artistTags") as? [String: [String]] ?? [:]
        let fresh = (d.object(forKey: "artistTagsAt") as? Date).map { Date().timeIntervalSince($0) < 30 * 86_400 } ?? false
        let artists = Library.shared.artists
        let missing = artists.filter { cache[Library.artistKey($0.name)] == nil || !fresh }
        guard !missing.isEmpty, LastFM.hasKey else { return cache }
        for (i, a) in missing.enumerated() {
            progress(String(localized: "Reading artist tags: \(i + 1) of \(missing.count)…"))
            cache[Library.artistKey(a.name)] = await LastFM.shared.artistTags(a.name)
        }
        d.set(cache, forKey: "artistTags")
        d.set(Date(), forKey: "artistTagsAt")
        return cache
    }
}

/// "Play something…" field with ready-made mixes, on the Recent tab.
struct SmartMixBar: View {
    @ObservedObject var player = Player.shared
    @State private var text = ""
    @State private var status: String?
    @State private var working = false

    private let presets: [LocalizedStringKey] = ["Calm", "Energetic", "Russian", "90s", "Favorites", "Forgotten", "Jazz", "Electronic"]
    private let presetText = ["спокойное", "энергичное", "русское", "90-е", "любимое", "давно не слушал", "джаз", "электроника"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Mix")
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").foregroundStyle(.secondary)
                TextField("For example: calm for work, Russian 90s", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { run(text) }
                if working { ProgressView().controlSize(.small) } else {
                    Button { run(text) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .glass(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(presets.indices, id: \.self) { i in
                        Button { run(presetText[i]) } label: {
                            Text(presets[i]).font(.system(size: 11))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .glass(Capsule(), interactive: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(working)
                    }
                }
                .padding(.horizontal, 12)
            }
            if let status { Text(status).font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.horizontal, 14) }
        }
        .padding(.bottom, 4)
    }

    private func run(_ s: String) {
        let s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        working = true
        status = nil
        Task {
            let tracks = await SmartMix.build(s) { status = $0 }
            working = false
            if tracks.isEmpty {
                status = String(localized: "Nothing matched “\(s)”")
            } else {
                player.play(tracks)
                status = String(localized: "Playing a mix: \(tracks.count) tracks")
            }
        }
    }
}
