import Foundation

/// Album covers in Emby: copy a track's embedded picture to its album, or find a cover in
/// Deezer / iTunes and save it to Emby, so every Emby client sees it. Runs only on user action.
@MainActor
enum Covers {
    /// Album id → cache-busting tag for covers changed in this session.
    nonisolated(unsafe) static var changed: [String: String] = [:]

    struct Candidate: Identifiable, Hashable {
        let id: String
        let source: String
        let title: String
        let thumb: URL
        let full: URL
    }

    // MARK: From track files

    /// For every album without a cover: takes the first track's own picture and saves it as the
    /// album cover. Returns how many albums got a cover and how many had nothing to take.
    static func fillFromTracks(progress: @escaping (Int, Int) -> Void) async -> (fixed: Int, missing: Int) {
        let albums = Library.shared.albums.flatMap { $0.parts ?? [$0] }.filter { $0.imageTag == nil }
        var fixed = 0, missing = 0
        for (i, a) in albums.enumerated() {
            progress(i + 1, albums.count)
            guard let tracks = try? await Emby.shared.tracks(album: a.Id),
                  let t = tracks.first(where: { $0.ImageTags?["Primary"] != nil }),
                  let (data, type) = await download(Emby.shared.url("/Items/\(t.Id)/Images/Primary")),
                  (try? await upload(data, type: type, to: a.Id)) != nil
            else { missing += 1; continue }
            changed[a.Id] = UUID().uuidString
            fixed += 1
        }
        return (fixed, missing)
    }

    // MARK: Search

    /// Cover candidates from Deezer and iTunes (both free, no key).
    static func search(artist: String, album: String) async -> [Candidate] {
        let term = [artist, album].filter { !$0.isEmpty }.joined(separator: " ")
        async let deezer = deezer(term)
        async let itunes = itunes(term)
        var seen = Set<String>()
        return (await deezer + itunes).filter { seen.insert($0.full.absoluteString).inserted }
    }

    private static func deezer(_ term: String) async -> [Candidate] {
        var c = URLComponents(string: "https://api.deezer.com/search/album")!
        c.queryItems = [.init(name: "q", value: term), .init(name: "limit", value: "6")]
        guard let (data, _) = await download(c.url!),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = o["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { a in
            guard let full = (a["cover_xl"] as? String).flatMap(URL.init(string:)),
                  let thumb = (a["cover_medium"] as? String).flatMap(URL.init(string:)) else { return nil }
            let artist = (a["artist"] as? [String: Any])?["name"] as? String ?? ""
            return Candidate(id: "dz\(a["id"] ?? "")", source: "Deezer",
                             title: [artist, a["title"] as? String ?? ""].joined(separator: " — "), thumb: thumb, full: full)
        }
    }

    private static func itunes(_ term: String) async -> [Candidate] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: term), .init(name: "entity", value: "album"), .init(name: "limit", value: "6")]
        guard let (data, _) = await download(c.url!),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = o["results"] as? [[String: Any]] else { return [] }
        return list.compactMap { a in
            guard let small = a["artworkUrl100"] as? String,
                  let thumb = URL(string: small.replacingOccurrences(of: "100x100bb", with: "300x300bb")),
                  let full = URL(string: small.replacingOccurrences(of: "100x100bb", with: "1400x1400bb")) else { return nil }
            return Candidate(id: "it\(a["collectionId"] ?? "")", source: "iTunes",
                             title: [a["artistName"] as? String ?? "", a["collectionName"] as? String ?? ""].joined(separator: " — "),
                             thumb: thumb, full: full)
        }
    }

    /// Downloads the picture and saves it as the cover of the album (each part of a compilation).
    static func apply(_ c: Candidate, to album: Album) async throws {
        guard let (data, type) = await download(c.full) else { throw PlayerError.http(0) }
        for part in album.parts ?? [album] {
            try await upload(data, type: type, to: part.Id)
            changed[part.Id] = UUID().uuidString
        }
    }

    // MARK: HTTP

    private static func download(_ url: URL) async -> (Data, String)? {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue("KlangPlayer (https://github.com/satsura/klang-player)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              let h = resp as? HTTPURLResponse, h.statusCode == 200, !data.isEmpty else { return nil }
        return (data, h.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg")
    }

    /// Emby takes the image base64-encoded in the body.
    private static func upload(_ data: Data, type: String, to itemId: String) async throws {
        var r = URLRequest(url: Emby.shared.url("/Items/\(itemId)/Images/Primary"))
        r.httpMethod = "POST"
        r.setValue(type.hasPrefix("image/") ? type : "image/jpeg", forHTTPHeaderField: "Content-Type")
        r.httpBody = data.base64EncodedData()
        let (_, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw PlayerError.http(code) }
    }
}
