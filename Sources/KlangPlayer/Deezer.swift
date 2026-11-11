import Foundation

/// Deezer's public API (no key): artist pictures, discographies with release dates, top tracks
/// with 30-second previews. Used for discovering music that isn't in the library.
enum Deezer {
    struct Artist: Codable, Hashable {
        let id: Int
        let name: String
        let picture_medium: String?
        let picture_big: String?
        let nb_fan: Int?
        let link: String?
    }
    struct Album: Codable, Hashable, Identifiable {
        let id: Int
        let title: String
        let cover_medium: String?
        let cover_big: String?
        let release_date: String?
        let record_type: String?
        let link: String?
        let artist: ArtistRef?
    }
    struct ArtistRef: Codable, Hashable { let name: String }
    struct Track: Codable, Hashable, Identifiable {
        let id: Int
        let title: String
        let duration: Int?
        let preview: String?
        let link: String?
        let album: AlbumRef?
    }
    struct AlbumRef: Codable, Hashable { let title: String?; let cover_small: String? }
    private struct List<T: Codable>: Codable { let data: [T]? }

    private static func get<T: Codable>(_ path: String, _ query: [String: String] = [:]) async -> T? {
        var c = URLComponents(string: "https://api.deezer.com" + path)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// The artist with exactly this name (ignoring case and punctuation), if Deezer has one.
    static func artist(named name: String) async -> Artist? {
        let r: List<Artist>? = await get("/search/artist", ["q": name, "limit": "5"])
        return r?.data?.first { Covers.key($0.name) == Covers.key(name) }
    }

    static func albums(of artistId: Int) async -> [Album] {
        let r: List<Album>? = await get("/artist/\(artistId)/albums", ["limit": "100"])
        return r?.data ?? []
    }

    static func topTracks(of artistId: Int, limit: Int = 10) async -> [Track] {
        let r: List<Track>? = await get("/artist/\(artistId)/top", ["limit": "\(limit)"])
        return r?.data ?? []
    }
}
