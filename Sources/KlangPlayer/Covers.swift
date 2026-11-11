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
        let artist: String
        let album: String
        let thumb: URL
        let full: URL
        var title: String { [artist, album].filter { !$0.isEmpty }.joined(separator: " — ") }
    }

    // MARK: Fill missing covers

    /// Every album without a cover, in three steps: the picture embedded in its tracks; for a part
    /// of a compilation, the cover of another part; else a cover from Deezer / iTunes, but only when
    /// artist and title match exactly. Existing covers are never replaced.
    static func fillMissing(progress: @escaping (Int, Int) -> Void) async -> (fixed: Int, missing: Int) {
        let fromFiles = await fillFromTracks(progress: progress)
        var fixed = fromFiles.fixed, missing = 0
        for album in Library.shared.albums {
            for part in album.parts ?? [album] where part.imageTag == nil && changed[part.Id] == nil {
                // A part of a compilation with a cover, or another disc of it ("… (CD1)" for "… (CD2)").
                let hasCover = { (a: Album) in a.imageTag != nil || changed[a.Id] != nil }
                let source = album.parts?.first(where: hasCover)
                    ?? Library.shared.albums.lazy.flatMap { $0.parts ?? [$0] }
                        .first { $0.Id != part.Id && key($0.Name) == key(part.Name) && hasCover($0) }
                if album.parts != nil, let source {
                    // Compilation split by Emby: all parts are the same album.
                    if let (data, type) = await download(Emby.shared.url("/Items/\(source.Id)/Images/Primary")),
                       (try? await upload(data, type: type, to: part.Id)) != nil {
                        changed[part.Id] = UUID().uuidString
                        fixed += 1
                        continue
                    }
                } else if let c = await exactMatch(artist: part.AlbumArtist ?? "", album: part.Name),
                          (try? await apply(c, to: part)) != nil {
                    debugLog("covers: \(part.Name): \(c.source) \(c.title)")
                    fixed += 1
                    continue
                }
                missing += 1
            }
        }
        return (fixed, missing)
    }

    /// "The Album (CD1) [Deluxe]" → "album": for comparing titles across services.
    nonisolated static func key(_ s: String) -> String {
        var t = s.lowercased()
            .replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&", with: "and")
        t = String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        for prefix in ["the", "a"] where t.hasPrefix(prefix) && t.count > prefix.count + 3 { t.removeFirst(prefix.count) }
        return t
    }

    /// A candidate whose artist and title match the album exactly (after `key`).
    static func exactMatch(artist: String, album: String) async -> Candidate? {
        guard !artist.isEmpty else { return nil }
        let title = album.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        let found = await search(artist: artist, album: title)
        return found.first { key($0.artist) == key(artist) && key($0.album) == key(album) }
    }

    // MARK: From track files

    /// For every album without a cover: takes the first track's own picture and saves it as the
    /// album cover. Returns how many albums got a cover and how many had nothing to take.
    static func fillFromTracks(progress: @escaping (Int, Int) -> Void) async -> (fixed: Int, missing: Int) {
        let albums = Library.shared.albums.flatMap { $0.parts ?? [$0] }.filter { $0.imageTag == nil }
        var fixed = 0, missing = 0
        for (i, a) in albums.enumerated() {
            progress(i + 1, albums.count)
            let tracks: [Track]
            do { tracks = try await Emby.shared.tracks(album: a.Id) } catch {
                debugLog("covers: \(a.Name): tracks \(error)"); missing += 1; continue
            }
            guard let t = tracks.first(where: { $0.ImageTags?["Primary"] != nil }) else {
                debugLog("covers: \(a.Name): no track picture among \(tracks.count)"); missing += 1; continue
            }
            guard let (data, type) = await download(Emby.shared.url("/Items/\(t.Id)/Images/Primary")) else {
                debugLog("covers: \(a.Name): download failed"); missing += 1; continue
            }
            do { try await upload(data, type: type, to: a.Id) } catch {
                debugLog("covers: \(a.Name): upload \(error)"); missing += 1; continue
            }
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
                             artist: artist, album: a["title"] as? String ?? "", thumb: thumb, full: full)
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
                             artist: a["artistName"] as? String ?? "", album: a["collectionName"] as? String ?? "",
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
