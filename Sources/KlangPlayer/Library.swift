import Foundation

struct Artist: Identifiable, Hashable {
    let name: String
    let albums: [Album]
    var id: String { name }
    var cover: Album? { albums.first { $0.imageTag != nil } ?? albums.first }
}

@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var albums: [Album] = []
    @Published private(set) var artists: [Artist] = []
    @Published private(set) var roots: [FolderEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var searchResults: [Track] = []

    // Home
    @Published private(set) var playlists: [FolderEntry] = []
    @Published private(set) var recentAlbums: [Album] = []
    @Published private(set) var recentTracks: [Track] = []
    @Published private(set) var topTracks: [Track] = []
    @Published private(set) var favoriteAlbums: [Album] = []
    @Published private(set) var favoriteTracks: [Track] = []
    /// Favorite state changed in this session (id → favorite), applied over server data.
    @Published private(set) var favoriteOverrides: [String: Bool] = [:]

    private var tracksCache: [String: [Track]] = [:]
    private var folderCache: [String: (folders: [FolderEntry], tracks: [Track])] = [:]
    private var searchTask: Task<Void, Never>?

    func load() async {
        guard Config.isConfigured else { error = PlayerError.notConfigured.localizedDescription; return }
        loading = true
        error = nil
        do {
            let a = try await Emby.shared.albums()
            albums = Album.mergeCompilations(a).sorted {
                // Compilations go last, the rest by artist and year.
                if ($0.parts != nil) != ($1.parts != nil) { return $1.parts != nil }
                let c = $0.artist.localizedStandardCompare($1.artist)
                return c == .orderedSame ? ($0.ProductionYear ?? 0) < ($1.ProductionYear ?? 0) : c == .orderedAscending
            }
            artists = Dictionary(grouping: a, by: { Library.artistKey($0.artist) })
                .map { _, albums in
                    // Show the most common spelling (ties: the one with more spaces, e.g. "A & B" over "A&B").
                    let names = Dictionary(grouping: albums.map(\.artist), by: { $0 })
                    let name = names.max { ($0.value.count, $0.key.filter { $0 == " " }.count) < ($1.value.count, $1.key.filter { $0 == " " }.count) }?.key ?? ""
                    return Artist(name: name.isEmpty ? String(localized: "Unknown artist") : name,
                                  albums: albums.sorted { ($0.ProductionYear ?? 0) < ($1.ProductionYear ?? 0) })
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            roots = (try? await Emby.shared.musicLibraries()) ?? []
            await loadHome()
            tracksCache = [:]
            folderCache = [:]
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    /// "Angus&Julia Stone" and "angus & julia  stone" are the same artist.
    nonisolated static func artistKey(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: #"\s*&\s*"#, with: " & ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    func loadHome() async {
        async let pl = try? Emby.shared.playlists()
        async let ra = try? Emby.shared.recentlyAdded()
        async let rt = try? Emby.shared.recentlyPlayed()
        async let tt = try? Emby.shared.mostPlayed()
        async let fa = try? Emby.shared.favoriteAlbums()
        async let ft = try? Emby.shared.favoriteTracks()
        playlists = await pl ?? []
        recentAlbums = await ra ?? []
        recentTracks = await rt ?? []
        topTracks = await tt ?? []
        favoriteAlbums = await fa ?? []
        favoriteTracks = await ft ?? []
    }

    func isFavorite(_ id: String, server: Bool) -> Bool { favoriteOverrides[id] ?? server }

    /// ♥ on a track: Emby favorite plus love on Last.fm.
    func toggleFavorite(_ t: Track) {
        let on = !isFavorite(t.Id, server: t.isFavorite)
        toggleFavorite(t.Id, current: !on)
        LastFM.shared.love(t, on)
    }

    // MARK: Popularity (Last.fm)

    /// Album id → listeners on Last.fm.
    @Published private(set) var listeners: [String: Int] = [:]
    /// Artist (lowercased) → normalized names of their top tracks.
    @Published private(set) var popular: [String: Set<String>] = [:]
    private var popularityLoading = false

    /// Fetches listeners for every album (a few per second; cached for a week).
    func loadPopularity() async {
        guard LastFM.hasKey, !popularityLoading else { return }
        popularityLoading = true
        defer { popularityLoading = false }
        for a in albums where a.parts == nil && listeners[a.Id] == nil {
            if let n = await LastFM.shared.albumListeners(artist: a.artist, album: a.Name) { listeners[a.Id] = n }
        }
    }

    func setListeners(_ n: Int, for albumId: String) { listeners[albumId] = n }

    func loadPopularTracks(_ artist: String) async {
        guard LastFM.hasKey, !artist.isEmpty, popular[artist.lowercased()] == nil else { return }
        popular[artist.lowercased()] = await LastFM.shared.topTracks(artist)
    }

    func isPopular(_ t: Track) -> Bool {
        popular[t.artist.lowercased()]?.contains(LastFM.normalize(t.Name)) == true
    }

    /// Albums without a cover in Emby: the picture embedded in their first track.
    @Published private(set) var trackCovers: [String: URL] = [:]
    private var trackCoverChecked = Set<String>()

    /// Cover to show for an album: its own, or (once loaded) one from its tracks.
    func coverURL(_ a: Album, size: Int) -> URL? {
        if let tag = Covers.changed[a.imageItemId] { return Emby.shared.imageURL(itemId: a.imageItemId, tag: tag, size: size) }
        return Emby.shared.imageURL(itemId: a.imageItemId, tag: a.imageTag, size: size) ?? trackCovers[a.Id]
    }

    /// For an album without a cover, looks for a track with its own picture (once per album).
    func loadTrackCover(_ a: Album) async {
        guard a.imageTag == nil, Covers.changed[a.imageItemId] == nil, trackCoverChecked.insert(a.Id).inserted,
              let tracks = try? await tracks(for: a),
              let url = tracks.first(where: { $0.ImageTags?["Primary"] != nil })?.artURL(size: 260) else { return }
        trackCovers[a.Id] = url
    }

    /// The album (or merged compilation) a track belongs to.
    func album(for t: Track) -> Album? {
        guard let id = t.AlbumId else { return nil }
        return albums.first { $0.Id == id || $0.parts?.contains { $0.Id == id } == true }
    }

    /// The current track's ♥ (for menus and the phone remote).
    var currentIsFavorite: Bool {
        Player.shared.current.map { isFavorite($0.Id, server: $0.isFavorite) } ?? false
    }

    func toggleFavorite(_ id: String, current: Bool) {
        favoriteOverrides[id] = !current
        Task {
            do {
                try await Emby.shared.setFavorite(id, !current)
                await loadHome()
            } catch {
                favoriteOverrides[id] = current
            }
        }
    }

    func playlistTracks(_ id: String) async throws -> [Track] {
        if let t = tracksCache["pl:" + id] { return t }
        let t = try await Emby.shared.playlistTracks(id)
        tracksCache["pl:" + id] = t
        return t
    }

    func tracks(for album: Album) async throws -> [Track] {
        if let t = tracksCache[album.Id] { return t }
        var t: [Track] = []
        for part in album.parts ?? [album] { t += try await Emby.shared.tracks(album: part.Id) }
        tracksCache[album.Id] = t
        return t
    }

    func children(of folder: String) async throws -> (folders: [FolderEntry], tracks: [Track]) {
        if let c = folderCache[folder] { return c }
        let c = try await Emby.shared.children(of: folder)
        folderCache[folder] = c
        return c
    }

    func filteredAlbums(_ q: String) -> [Album] {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return albums }
        return albums.filter {
            $0.Name.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
        }
    }

    func filteredArtists(_ q: String) -> [Artist] {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return artists }
        return artists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    func search(_ q: String) {
        searchTask?.cancel()
        let q = q.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { searchResults = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let r = (try? await Emby.shared.searchTracks(q)) ?? []
            guard !Task.isCancelled else { return }
            searchResults = r
        }
    }
}
