import Foundation

struct Album: Identifiable, Hashable, Decodable {
    let Id: String
    let Name: String
    let AlbumArtist: String?
    let ProductionYear: Int?
    let ImageTags: [String: String]?
    var UserData: UserItemData? = nil
    /// Set for a compilation that Emby split into one album per artist.
    var parts: [Album]? = nil
    var coverId: String? = nil

    var id: String { Id }
    var artist: String { parts != nil ? String(localized: "Compilation") : AlbumArtist ?? "" }
    var imageTag: String? { ImageTags?["Primary"] }
    var imageItemId: String { coverId ?? Id }

    /// Merges albums with the same name and several different album artists into one compilation.
    static func mergeCompilations(_ albums: [Album]) -> [Album] {
        let groups = Dictionary(grouping: albums, by: \.Name)
        var out: [Album] = []
        var done = Set<String>()
        for a in albums where !done.contains(a.Name) {
            let g = groups[a.Name] ?? [a]
            if g.count >= 3, Set(g.map(\.artist)).count >= 3 {
                done.insert(a.Name)
                let withCover = g.first { $0.imageTag != nil }
                out.append(Album(Id: "compilation:" + a.Name, Name: a.Name, AlbumArtist: nil,
                                 ProductionYear: g.compactMap(\.ProductionYear).min(),
                                 ImageTags: withCover?.ImageTags, parts: g, coverId: withCover?.Id))
            } else {
                out.append(a)
            }
        }
        return out
    }
}

struct UserItemData: Hashable, Codable {
    var IsFavorite: Bool?
    var PlayCount: Int?
}

struct MediaStream: Hashable, Codable {
    let `Type`: String?
    let Codec: String?
    let SampleRate: Int?
    let BitDepth: Int?
}

struct MediaSource: Hashable, Codable {
    let Container: String?
    let MediaStreams: [MediaStream]?
}

struct Track: Identifiable, Hashable, Codable {
    let Id: String
    let Name: String
    let Album: String?
    let AlbumId: String?
    let AlbumArtist: String?
    let Artists: [String]?
    let RunTimeTicks: Int64?
    let IndexNumber: Int?
    let ParentIndexNumber: Int?
    let AlbumPrimaryImageTag: String?
    var ImageTags: [String: String]? = nil       // the track's own (embedded) cover
    let MediaSources: [MediaSource]?
    var UserData: UserItemData? = nil

    var id: String { Id }
    var isFavorite: Bool { UserData?.IsFavorite ?? false }
    /// Album cover, or the track's own cover when the album has none in Emby.
    func artURL(size: Int) -> URL? {
        // A cover just set in the app: the track still carries the old (or no) tag.
        if let id = AlbumId, let tag = Covers.changed[id] { return Emby.shared.imageURL(itemId: id, tag: tag, size: size) }
        if let tag = AlbumPrimaryImageTag { return Emby.shared.imageURL(itemId: AlbumId, tag: tag, size: size) }
        return Emby.shared.imageURL(itemId: Id, tag: ImageTags?["Primary"], size: size)
    }
    var duration: Double { Double(RunTimeTicks ?? 0) / 10_000_000 }
    var artist: String { Artists?.first ?? AlbumArtist ?? "" }
    private var audioStream: MediaStream? {
        MediaSources?.first?.MediaStreams?.first { $0.Type == "Audio" }
    }
    var codec: String { (audioStream?.Codec ?? "").lowercased() }
    /// More than CD quality: over 16 bit or over 48 kHz.
    var isHiRes: Bool { (audioStream?.BitDepth ?? 16) > 16 || (audioStream?.SampleRate ?? 44_100) > 48_000 }
    var sampleRate: Int? { audioStream?.SampleRate }
    var container: String { (MediaSources?.first?.Container ?? "flac").lowercased() }

    /// "FLAC 24/96" — what the source file is.
    var sourceLabel: String {
        var s = codec.uppercased()
        if let sr = sampleRate {
            let khz = Double(sr) / 1000
            let k = khz == khz.rounded() ? String(Int(khz)) : String(format: "%.1f", khz)
            s += " \(audioStream?.BitDepth.map { "\($0)/" } ?? "")\(k)"
        }
        return s
    }
}

/// A row in folder view: a folder or an audio file.
struct FolderEntry: Identifiable, Hashable, Decodable {
    let Id: String
    let Name: String
    let `Type`: String
    let IsFolder: Bool?
    let ChildCount: Int?
    let ImageTags: [String: String]?
    let CollectionType: String?

    var id: String { Id }
    var isFolder: Bool { IsFolder ?? false }
    var imageTag: String? { ImageTags?["Primary"] }
}

private struct ItemsResponse<T: Decodable>: Decodable {
    let Items: [T]
}

private struct EmbyUser: Decodable {
    let Id: String
    let Name: String
}

private struct AuthResponse: Decodable {
    let AccessToken: String
    let User: EmbyUser
}

final class Emby {
    static let shared = Emby()

    private func base(_ server: String = Config.embyURL) -> String {
        var b = server
        while b.hasSuffix("/") { b.removeLast() }
        if !b.hasPrefix("http") { b = "http://" + b }
        return b + "/emby"
    }

    func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents(string: base() + path)!
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "api_key", value: Config.apiKey)]
        return c.url!
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        guard !Config.embyURL.isEmpty, !Config.apiKey.isEmpty else { throw PlayerError.notConfigured }
        let (data, resp) = try await URLSession.shared.data(from: url(path, query))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw PlayerError.http(code) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Identifies this app as an Emby client device (needed for session reporting).
    var authHeader: String {
        let device = (Host.current().localizedName ?? "Mac").replacingOccurrences(of: "\"", with: "")
        return "Emby UserId=\"\(Config.userId)\", Client=\"KlangPlayer\", Device=\"\(device)\", "
            + "DeviceId=\"\(Config.deviceId)\", Version=\"1.0\", Token=\"\(Config.apiKey)\""
    }

    /// Logs in with username/password, returns access token and user id.
    func login(server: String, user: String, password: String) async throws -> (token: String, userId: String) {
        guard let u = URL(string: base(server) + "/Users/AuthenticateByName") else { throw PlayerError.login(String(localized: "Invalid server address")) }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let device = (Host.current().localizedName ?? "Mac").replacingOccurrences(of: "\"", with: "")
        r.setValue("Emby Client=\"KlangPlayer\", Device=\"\(device)\", DeviceId=\"\(Config.deviceId)\", Version=\"1.0\"",
                   forHTTPHeaderField: "X-Emby-Authorization")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["Username": user, "Pw": password])
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw PlayerError.login(code == 401 ? String(localized: "Wrong username or password") : String(localized: "Emby returned \(code)")) }
        let a = try JSONDecoder().decode(AuthResponse.self, from: data)
        return (a.AccessToken, a.User.Id)
    }

    private func userId() async throws -> String {
        if !Config.userId.isEmpty { return Config.userId }
        let users: [EmbyUser] = try await get("/Users")
        guard let u = users.first else { throw PlayerError.http(404) }
        Config.userId = u.Id
        return u.Id
    }

    func albums() async throws -> [Album] {
        let uid = try await userId()
        let r: ItemsResponse<Album> = try await get("/Users/\(uid)/Items", [
            "Recursive": "true",
            "IncludeItemTypes": "MusicAlbum",
            "SortBy": "AlbumArtist,ProductionYear,SortName",
            "Fields": "ProductionYear",
        ])
        return r.Items
    }

    private let trackFields = "MediaSources"

    func track(id: String) async throws -> Track? {
        let uid = try await userId()
        let r: ItemsResponse<Track> = try await get("/Users/\(uid)/Items", ["Ids": id, "Fields": trackFields])
        return r.Items.first
    }

    func tracks(album: String) async throws -> [Track] {
        let uid = try await userId()
        let r: ItemsResponse<Track> = try await get("/Users/\(uid)/Items", [
            "ParentId": album,
            "Recursive": "true",
            "IncludeItemTypes": "Audio",
            "SortBy": "ParentIndexNumber,IndexNumber,SortName",
            "Fields": trackFields,
        ])
        return r.Items
    }

    func searchTracks(_ q: String) async throws -> [Track] {
        let uid = try await userId()
        let r: ItemsResponse<Track> = try await get("/Users/\(uid)/Items", [
            "Recursive": "true",
            "IncludeItemTypes": "Audio",
            "SearchTerm": q,
            "Limit": "40",
            "Fields": trackFields,
        ])
        return r.Items
    }

    /// Music libraries — roots of folder view.
    func musicLibraries() async throws -> [FolderEntry] {
        let uid = try await userId()
        let r: ItemsResponse<FolderEntry> = try await get("/Users/\(uid)/Views")
        return r.Items.filter { $0.CollectionType == "music" }
    }

    /// Direct children of a folder: subfolders first, then audio files in track order.
    func children(of parent: String) async throws -> (folders: [FolderEntry], tracks: [Track]) {
        let uid = try await userId()
        let q = ["ParentId": parent, "SortBy": "SortName", "Fields": "MediaSources,ChildCount"]
        guard !Config.apiKey.isEmpty else { throw PlayerError.notConfigured }
        let (data, resp) = try await URLSession.shared.data(from: url("/Users/\(uid)/Items", q))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw PlayerError.http(code) }
        let entries = try JSONDecoder().decode(ItemsResponse<FolderEntry>.self, from: data).Items
        let all = try JSONDecoder().decode(ItemsResponse<Track>.self, from: data).Items
        let audioIds = Set(entries.filter { $0.Type == "Audio" }.map(\.Id))
        let folders = entries.filter(\.isFolder)
            .sorted { $0.Name.localizedStandardCompare($1.Name) == .orderedAscending }
        let tracks = all.filter { audioIds.contains($0.Id) }.sorted {
            ($0.ParentIndexNumber ?? 0, $0.IndexNumber ?? 0, $0.Name) < ($1.ParentIndexNumber ?? 0, $1.IndexNumber ?? 0, $1.Name)
        }
        return (folders, tracks)
    }

    /// Every audio file under a folder, recursively.
    func allTracks(under parent: String) async throws -> [Track] {
        let uid = try await userId()
        let r: ItemsResponse<Track> = try await get("/Users/\(uid)/Items", [
            "ParentId": parent,
            "Recursive": "true",
            "IncludeItemTypes": "Audio",
            "SortBy": "AlbumArtist,Album,ParentIndexNumber,IndexNumber,SortName",
            "Fields": trackFields,
        ])
        return r.Items
    }

    // MARK: Home

    private func userTracks(_ q: [String: String]) async throws -> [Track] {
        let uid = try await userId()
        var q = q
        q["Recursive"] = "true"
        q["IncludeItemTypes"] = "Audio"
        q["Fields"] = trackFields
        let r: ItemsResponse<Track> = try await get("/Users/\(uid)/Items", q)
        return r.Items
    }

    func recentlyPlayed(limit: Int = 30) async throws -> [Track] {
        try await userTracks(["Filters": "IsPlayed", "SortBy": "DatePlayed", "SortOrder": "Descending", "Limit": "\(limit)"])
    }

    func mostPlayed(limit: Int = 30) async throws -> [Track] {
        try await userTracks(["Filters": "IsPlayed", "SortBy": "PlayCount,DatePlayed", "SortOrder": "Descending", "Limit": "\(limit)"])
    }

    func favoriteTracks() async throws -> [Track] {
        try await userTracks(["Filters": "IsFavorite", "SortBy": "AlbumArtist,Album,IndexNumber"])
    }

    func favoriteAlbums() async throws -> [Album] {
        let uid = try await userId()
        let r: ItemsResponse<Album> = try await get("/Users/\(uid)/Items", [
            "Recursive": "true", "IncludeItemTypes": "MusicAlbum", "Filters": "IsFavorite", "SortBy": "AlbumArtist,SortName",
        ])
        return r.Items
    }

    func recentlyAdded(limit: Int = 16) async throws -> [Album] {
        let uid = try await userId()
        let r: ItemsResponse<Album> = try await get("/Users/\(uid)/Items", [
            "Recursive": "true", "IncludeItemTypes": "MusicAlbum", "SortBy": "DateCreated", "SortOrder": "Descending",
            "Limit": "\(limit)", "Fields": "ProductionYear",
        ])
        return r.Items
    }

    func playlists() async throws -> [FolderEntry] {
        let uid = try await userId()
        let r: ItemsResponse<FolderEntry> = try await get("/Users/\(uid)/Items", [
            "Recursive": "true", "IncludeItemTypes": "Playlist", "SortBy": "SortName", "Fields": "ChildCount",
        ])
        return r.Items
    }

    func playlistTracks(_ id: String) async throws -> [Track] {
        let uid = try await userId()
        let r: ItemsResponse<Track> = try await get("/Playlists/\(id)/Items", ["UserId": uid, "Fields": trackFields])
        return r.Items
    }

    /// Marks or unmarks an item (track or album) as favorite.
    /// Artist biography from Emby, if it has one.
    func artistOverview(_ name: String) async -> String? {
        let uid = (try? await userId()) ?? ""
        let path = "/Artists/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? name)
        guard let (data, _) = try? await URLSession.shared.data(from: url(path, ["UserId": uid, "Fields": "Overview"])),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = (o["Overview"] as? String).map(LastFM.plainText), !text.isEmpty else { return nil }
        return text
    }

    func setFavorite(_ id: String, _ on: Bool) async throws {
        let uid = try await userId()
        var r = URLRequest(url: url("/Users/\(uid)/FavoriteItems/\(id)"))
        r.httpMethod = on ? "POST" : "DELETE"
        let (_, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw PlayerError.http(code) }
    }

    func imageURL(itemId: String?, tag: String?, size: Int) -> URL? {
        guard let itemId, let tag else { return nil }
        return url("/Items/\(itemId)/Images/Primary", ["maxHeight": "\(size)", "quality": "90", "tag": tag])
    }

    func originalURL(_ t: Track) -> URL {
        url("/Audio/\(t.Id)/stream", ["static": "true"])
    }

    /// Live MP3 stream: fallback when a track can't be converted locally.
    func mp3URL(_ t: Track) -> URL {
        url("/Audio/\(t.Id)/stream.mp3", ["AudioCodec": "mp3", "AudioBitrate": "320000"])
    }
}
