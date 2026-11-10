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
                let c = $0.artist.localizedStandardCompare($1.artist)
                return c == .orderedSame ? ($0.ProductionYear ?? 0) < ($1.ProductionYear ?? 0) : c == .orderedAscending
            }
            artists = Dictionary(grouping: a, by: { $0.artist.isEmpty ? "Без артиста" : $0.artist })
                .map { Artist(name: $0.key, albums: $0.value.sorted { ($0.ProductionYear ?? 0) < ($1.ProductionYear ?? 0) }) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            roots = (try? await Emby.shared.musicLibraries()) ?? []
            tracksCache = [:]
            folderCache = [:]
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
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
