import AVFoundation
import SwiftUI

/// Music that isn't in the library: new releases of the user's artists and artists similar to
/// what they listen to most (Last.fm history + Deezer for pictures, dates and previews).
@MainActor
final class DiscoverStore: ObservableObject {
    static let shared = DiscoverStore()

    struct Release: Codable, Identifiable, Hashable {
        let id: Int
        let title: String
        let artist: String
        let cover: String?
        let date: String
        let type: String
        let link: String?
    }
    struct Suggestion: Codable, Identifiable, Hashable {
        let name: String
        let picture: String?
        let fans: Int?
        let because: [String]
        var id: String { name }
    }
    private struct Saved: Codable {
        let releases: [Release]
        let suggestions: [Suggestion]
        let at: Date
    }

    @Published private(set) var releases: [Release] = []
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var loading = false
    @Published private(set) var updated: Date?

    init() {
        if let d = UserDefaults.standard.data(forKey: "discover"), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            releases = s.releases
            suggestions = s.suggestions
            updated = s.at
        }
    }

    /// Reloads when older than a day (or when forced).
    func load(force: Bool = false) async {
        guard !loading, force || updated.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true else { return }
        let lib = Library.shared
        if lib.artists.isEmpty { await lib.load() }
        guard !lib.artists.isEmpty else { return }
        loading = true
        defer { loading = false }

        let libKeys = Set(lib.artists.map { Library.artistKey($0.name) })
        // Seeds: the user's most played artists on Last.fm (last 6 months), else the library's biggest.
        var seeds = await LastFM.shared.userTop("artists", period: "6month", limit: 20).map(\.name)
        if seeds.isEmpty { seeds = lib.artists.sorted { $0.albums.count > $1.albums.count }.prefix(15).map(\.name) }

        // New releases of library artists the user listens to.
        let mine = (seeds.filter { libKeys.contains(Library.artistKey($0)) } + lib.artists.map(\.name))
        var seenArtists = Set<String>()
        let artistsToCheck = mine.filter { seenArtists.insert(Library.artistKey($0)).inserted }.prefix(14)
        let cutoff = Calendar.current.date(byAdding: .month, value: -18, to: Date())!
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var found: [Release] = []
        for name in artistsToCheck {
            guard let a = await Deezer.artist(named: name) else { continue }
            let owned = Set((lib.artists.first { Library.artistKey($0.name) == Library.artistKey(name) }?.albums ?? []).map { Covers.key($0.Name) })
            for al in await Deezer.albums(of: a.id) {
                guard let ds = al.release_date, let d = df.date(from: ds), d >= cutoff,
                      al.record_type != "single", !owned.contains(Covers.key(al.title)) else { continue }
                found.append(Release(id: al.id, title: al.title, artist: a.name, cover: al.cover_big ?? al.cover_medium,
                                     date: ds, type: al.record_type ?? "album", link: al.link))
            }
        }
        var seenTitles = Set<String>()
        releases = found.sorted { $0.date > $1.date }.filter { seenTitles.insert(Covers.key($0.artist + $0.title)).inserted }

        // Similar artists that aren't in the library, scored over several seeds.
        var score: [String: (name: String, value: Double, because: [String])] = [:]
        let seedKeys = Set(seeds.map(Library.artistKey))
        for (rank, seed) in seeds.prefix(10).enumerated() {
            let weight = 1.0 / Double(rank + 2).squareRoot()
            for s in await LastFM.shared.similarArtistsScored(seed, limit: 40) {
                let k = Library.artistKey(s.name)
                guard !libKeys.contains(k), !seedKeys.contains(k) else { continue }
                var e = score[k] ?? (s.name, 0, [])
                e.value += s.match * weight
                if e.because.count < 3 { e.because.append(seed) }
                score[k] = e
            }
        }
        var out: [Suggestion] = []
        for e in score.values.sorted(by: { $0.value > $1.value }).prefix(18) {
            let a = await Deezer.artist(named: e.name)
            out.append(Suggestion(name: e.name, picture: a?.picture_big ?? a?.picture_medium, fans: a?.nb_fan, because: e.because))
        }
        suggestions = out
        updated = Date()
        if let d = try? JSONEncoder().encode(Saved(releases: releases, suggestions: suggestions, at: updated!)) {
            UserDefaults.standard.set(d, forKey: "discover")
        }
    }
}

struct DiscoverView: View {
    @ObservedObject var store = DiscoverStore.shared
    let open: (Route) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !LastFM.isConnected {
                    Text("Connect Last.fm in Settings: suggestions then follow what you actually listen to.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.top, 8)
                }
                if !store.releases.isEmpty {
                    SectionTitle("New from Your Artists")
                    Shelf {
                        ForEach(store.releases) { r in
                            DiscoverTile(image: r.cover, title: r.title, subtitle: "\(r.artist) · \(r.date.prefix(4))") {
                                open(.newArtist(r.artist))
                            }
                            .contextMenu { links(artist: r.artist, album: r.title, deezer: r.link) }
                        }
                    }
                }
                if !store.suggestions.isEmpty {
                    SectionTitle("You Might Like")
                    ForEach(store.suggestions) { s in
                        Button { open(.newArtist(s.name)) } label: {
                            HStack(spacing: 10) {
                                Cover(url: s.picture.flatMap(URL.init(string:)), size: 42, radius: 21, placeholder: "music.mic")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: s.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    Text(verbatim: String(localized: "Like \(s.because.joined(separator: ", "))"))
                                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if let f = s.fans, f > 0 {
                                    Text(verbatim: f.formatted(.number.notation(.compactName)))
                                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                                        .help("Fans on Deezer")
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverable()
                        .contextMenu { links(artist: s.name, album: nil, deezer: nil) }
                    }
                }
                if store.loading {
                    HStack { ProgressView().controlSize(.small); Text("Looking for music…").font(.system(size: 11)).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity).padding(20)
                } else if store.releases.isEmpty && store.suggestions.isEmpty {
                    EmptyState(icon: "sparkles", text: String(localized: "Nothing found yet"))
                }
                if let u = store.updated, !store.loading {
                    HStack {
                        Text("Updated \(u.formatted(.relative(presentation: .named)))").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        Button("Refresh") { Task { await store.load(force: true) } }.buttonStyle(.link).font(.system(size: 9.5))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
            }
            .padding(.bottom, 6)
        }
        .task { await store.load() }
    }
}

/// "Open in …" links for music that isn't in the library.
@ViewBuilder
func links(artist: String, album: String?, deezer: String?) -> some View {
    let q = [artist, album ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
    Button("Open in Apple Music") { NSWorkspace.shared.open(URL(string: "https://music.apple.com/search?term=\(enc)")!) }
    Button("Open in YouTube Music") { NSWorkspace.shared.open(URL(string: "https://music.youtube.com/search?q=\(enc)")!) }
    Button("Open in Deezer") {
        NSWorkspace.shared.open(deezer.flatMap(URL.init(string:)) ?? URL(string: "https://www.deezer.com/search/\(enc)")!)
    }
    Button("Open on Last.fm") {
        let a = artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artist
        NSWorkspace.shared.open(URL(string: "https://www.last.fm/music/\(a)")!)
    }
}

struct DiscoverTile: View {
    let image: String?
    let title: String
    let subtitle: String
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                Cover(url: image.flatMap(URL.init(string:)), size: 112)
                Text(verbatim: title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(verbatim: subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 112)
        }
        .buttonStyle(.plain)
    }
}

/// 30-second previews, played on this Mac (the speaker keeps its queue).
@MainActor
final class PreviewPlayer: ObservableObject {
    static let shared = PreviewPlayer()
    @Published private(set) var playing: Int?
    private var player: AVPlayer?
    private var end: NSObjectProtocol?

    func toggle(_ id: Int, url: URL) {
        if playing == id { stop(); return }
        stop()
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.play()
        playing = id
        end = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            MainActor.assumeIsolated { PreviewPlayer.shared.stop() }
        }
    }

    func stop() {
        player?.pause()
        player = nil
        playing = nil
        if let end { NotificationCenter.default.removeObserver(end) }
        end = nil
    }
}

/// An artist outside the library: picture, top tracks with previews, albums, bio and links.
struct NewArtistView: View {
    let name: String
    let back: () -> Void
    @ObservedObject private var preview = PreviewPlayer.shared
    @State private var artist: Deezer.Artist?
    @State private var top: [Deezer.Track] = []
    @State private var albums: [Deezer.Album] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(title: name, back: { preview.stop(); back() })
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Cover(url: (artist?.picture_big).flatMap(URL.init(string:)), size: 84, radius: 42, placeholder: "music.mic")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: name).font(.system(size: 15, weight: .semibold))
                            if let f = artist?.nb_fan, f > 0 {
                                Text("\(f.formatted(.number.notation(.compactName))) fans on Deezer").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                            Menu("Listen in…") { links(artist: name, album: nil, deezer: artist?.link) }
                                .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
                        }
                        Spacer()
                    }
                    .padding(14)
                    AboutSection(subject: .artist(name))
                    if !top.isEmpty {
                        SectionTitle("Top Tracks")
                        ForEach(top) { t in
                            HStack(spacing: 10) {
                                Button {
                                    if let p = t.preview.flatMap(URL.init(string:)) { preview.toggle(t.id, url: p) }
                                } label: {
                                    Image(systemName: preview.playing == t.id ? "stop.circle.fill" : "play.circle")
                                        .font(.system(size: 18))
                                }
                                .buttonStyle(.borderless)
                                .disabled(t.preview == nil)
                                .help("30-second preview on this Mac")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: t.title).font(.system(size: 12)).lineLimit(1)
                                    Text(verbatim: t.album?.title ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(mmss(Double(t.duration ?? 0))).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 4)
                        }
                    }
                    if !albums.isEmpty {
                        SectionTitle("Albums")
                        Shelf {
                            ForEach(albums) { a in
                                DiscoverTile(image: a.cover_big ?? a.cover_medium, title: a.title,
                                             subtitle: String((a.release_date ?? "").prefix(4))) {
                                    if let l = a.link.flatMap(URL.init(string:)) { NSWorkspace.shared.open(l) }
                                }
                                .contextMenu { links(artist: name, album: a.title, deezer: a.link) }
                            }
                        }
                    }
                    if loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(20) }
                }
                .padding(.bottom, 10)
            }
        }
        .task(id: name) {
            artist = await Deezer.artist(named: name)
            if let a = artist {
                async let t = Deezer.topTracks(of: a.id)
                async let al = Deezer.albums(of: a.id)
                top = await t
                albums = await al.filter { $0.record_type != "single" }.sorted { ($0.release_date ?? "") > ($1.release_date ?? "") }
            }
            loading = false
        }
        .onDisappear { preview.stop() }
    }
}
