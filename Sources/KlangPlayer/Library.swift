import Foundation

struct Artist: Identifiable, Hashable {
    let name: String
    let albums: [Album]
    var id: String { name }
    var cover: Album? { albums.first { $0.imageTag != nil } }
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
