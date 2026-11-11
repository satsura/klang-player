import AppKit
import CryptoKit
import Foundation

/// Last.fm: scrobbling, "now playing", love, and album / artist descriptions.
/// The API key and secret are the user's own (Settings); nothing is built into the app.
@MainActor
final class LastFM {
    static let shared = LastFM()

    // MARK: Settings

    private static let d = UserDefaults.standard
    static var apiKey: String {
        get { d.string(forKey: "lastfmKey") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "lastfmKey") }
    }
    static var secret: String {
        get { d.string(forKey: "lastfmSecret") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "lastfmSecret") }
    }
    static var sessionKey: String {
        get { d.string(forKey: "lastfmSession") ?? "" }
        set { d.set(newValue, forKey: "lastfmSession") }
    }
    static var userName: String {
        get { d.string(forKey: "lastfmUser") ?? "" }
        set { d.set(newValue, forKey: "lastfmUser") }
    }
    static var scrobbling: Bool {
        get { d.object(forKey: "lastfmScrobble") as? Bool ?? true }
        set { d.set(newValue, forKey: "lastfmScrobble") }
    }

    static var hasKey: Bool { !apiKey.isEmpty }
    static var isConnected: Bool { hasKey && !secret.isEmpty && !sessionKey.isEmpty }

    // MARK: Sign-in (desktop flow: token → user allows in the browser → session)

    /// Opens Last.fm in the browser and waits (up to 3 minutes) until the user allows access.
    func connect() async throws -> String {
        let token = try await call("auth.getToken", signed: true)["token"] as? String ?? ""
        guard !token.isEmpty else { throw LastFMError.message("no token") }
        var c = URLComponents(string: "https://www.last.fm/api/auth/")!
        c.queryItems = [.init(name: "api_key", value: Self.apiKey), .init(name: "token", value: token)]
        NSWorkspace.shared.open(c.url!)
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            // Error 14 "unauthorized token" until the user clicks Allow.
            guard let r = try? await call("auth.getSession", ["token": token], signed: true),
                  let s = r["session"] as? [String: Any], let key = s["key"] as? String else { continue }
            Self.sessionKey = key
            Self.userName = s["name"] as? String ?? ""
            return Self.userName
        }
        throw LastFMError.message(String(localized: "Access wasn't allowed in time"))
    }

    func disconnect() {
        Self.sessionKey = ""
        Self.userName = ""
    }

    // MARK: Scrobbling

    private var playing: (track: Track, started: Date)?

    /// A track started: tell Last.fm what's playing.
    func started(_ t: Track) {
        playing = (t, Date())
        guard Self.isConnected, Self.scrobbling, !Speaker.dryRun else { return }
        var p = trackParams(t)
        if t.duration > 0 { p["duration"] = "\(Int(t.duration))" }
        Task { _ = try? await call("track.updateNowPlaying", p, signed: true, post: true) }
    }

    /// The track ended after `played` seconds: scrobble it if it counts
    /// (Last.fm rules: longer than 30 s, played for half its length or 4 minutes).
    func finished(_ t: Track, played: Double) {
        defer { playing = nil }
        guard let p = playing, p.track.Id == t.Id, Self.isConnected, Self.scrobbling, !Speaker.dryRun,
              t.duration > 30, played >= min(t.duration / 2, 240) else { return }
        var params = trackParams(t)
        params["timestamp"] = "\(Int(p.started.timeIntervalSince1970))"
        if t.duration > 0 { params["duration"] = "\(Int(t.duration))" }
        Task { await scrobble(params) }
    }

    /// Sends a scrobble; failed ones are kept and sent again with the next one.
    private func scrobble(_ params: [String: String]) async {
        var pending = Self.d.array(forKey: "lastfmPending") as? [[String: String]] ?? []
        pending.append(params)
        var left: [[String: String]] = []
        for p in pending.suffix(200) {
            do { _ = try await call("track.scrobble", p, signed: true, post: true) } catch {
                debugLog("last.fm scrobble: \(error.localizedDescription)")
                left.append(p)
            }
        }
        Self.d.set(left, forKey: "lastfmPending")
    }

    /// ♥ on a track → love / unlove on Last.fm.
    func love(_ t: Track, _ on: Bool) {
        guard Self.isConnected, !Speaker.dryRun else { return }
        let p = ["artist": t.artist, "track": t.Name]
        Task {
            do { _ = try await call(on ? "track.love" : "track.unlove", p, signed: true, post: true) } catch {
                debugLog("last.fm love: \(error.localizedDescription)")
            }
        }
    }

    private func trackParams(_ t: Track) -> [String: String] {
        var p = ["artist": t.artist, "track": t.Name]
        if let a = t.Album, !a.isEmpty { p["album"] = a }
        if let aa = t.AlbumArtist, !aa.isEmpty, aa != t.artist { p["albumArtist"] = aa }
        return p
    }

    // MARK: Descriptions

    struct Info: Equatable {
        let summary: String?
        let tags: [String]
        let url: URL?
        var listeners: Int? = nil
        var playcount: Int? = nil
    }

    private var infoCache: [String: Info?] = [:]

    func albumInfo(artist: String, album: String) async -> Info? {
        await info("album:\(artist)|\(album)", "album.getInfo", ["artist": artist, "album": album], root: "album")
    }

    func artistInfo(_ artist: String) async -> Info? {
        await info("artist:\(artist)", "artist.getInfo", ["artist": artist], root: "artist")
    }

    private func info(_ key: String, _ method: String, _ params: [String: String], root: String) async -> Info? {
        if let cached = infoCache[key] { return cached }
        guard Self.hasKey else { return nil }
        var p = params
        p["autocorrect"] = "1"
        let lang = Bundle.main.preferredLocalizations.first == "ru" ? "ru" : "en"
        p["lang"] = lang
        guard let r = try? await call(method, p), let o = r[root] as? [String: Any] else { return nil }
        let tags = ((o["tags"] as? [String: Any])?["tag"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        func summary(_ o: [String: Any]) -> String? {
            let wiki = (o["wiki"] ?? o["bio"]) as? [String: Any]
            return (wiki?["summary"] as? String).map(Self.plainText).flatMap { $0.isEmpty ? nil : $0 }
        }
        var text = summary(o)
        // No description in Russian: take the English one.
        if text == nil, lang != "en" {
            p["lang"] = "en"
            if let r2 = try? await call(method, p), let o2 = r2[root] as? [String: Any] { text = summary(o2) }
        }
        // Album: listeners / playcount at the top level; artist: inside "stats".
        let stats = (o["stats"] as? [String: Any]) ?? o
        let info = Info(summary: text, tags: Array(tags.prefix(5)), url: (o["url"] as? String).flatMap(URL.init(string:)),
                        listeners: (stats["listeners"] as? String).flatMap(Int.init),
                        playcount: (stats["playcount"] as? String).flatMap(Int.init))
        infoCache[key] = info
        return info
    }

    // MARK: Popularity

    /// Album listeners on Last.fm, cached on disk for a week (it's for sorting, not live numbers).
    func albumListeners(artist: String, album: String) async -> Int? {
        let key = "\(artist)|\(album)".lowercased()
        var cache = Self.d.dictionary(forKey: "lastfmListeners") as? [String: [Double]] ?? [:]
        if let c = cache[key], c.count == 2, Date().timeIntervalSince1970 - c[1] < 7 * 86_400 { return c[0] < 0 ? nil : Int(c[0]) }
        guard Self.hasKey else { return nil }
        let p = ["artist": artist, "album": album, "autocorrect": "1"]
        guard let r = try? await call("album.getInfo", p) else {
            return nil   // network error: don't cache
        }
        let n = ((r["album"] as? [String: Any])?["listeners"] as? String).flatMap(Int.init)
        cache[key] = [Double(n ?? -1), Date().timeIntervalSince1970]
        Self.d.set(cache, forKey: "lastfmListeners")
        return n
    }

    private var similarCache: [String: [(name: String, match: Double)]] = [:]

    /// Similar artists on Last.fm, most similar first.
    func similarArtists(_ artist: String, limit: Int = 30) async -> [String] {
        await similarArtistsScored(artist, limit: limit).map(\.name)
    }

    /// Similar artists with Last.fm's similarity (0…1).
    func similarArtistsScored(_ artist: String, limit: Int = 30) async -> [(name: String, match: Double)] {
        let key = artist.lowercased()
        if let c = similarCache[key] { return c }
        guard Self.hasKey,
              let r = try? await call("artist.getSimilar", ["artist": artist, "autocorrect": "1", "limit": "\(limit)"]),
              let list = (r["similarartists"] as? [String: Any])?["artist"] as? [[String: Any]] else { return [] }
        let out = list.compactMap { a -> (String, Double)? in
            guard let n = a["name"] as? String else { return nil }
            return (n, Double(a["match"] as? String ?? "") ?? 0)
        }
        similarCache[key] = out
        return out
    }

    /// The artist's top tags (lowercased), most used first.
    func artistTags(_ artist: String) async -> [String] {
        guard Self.hasKey,
              let r = try? await call("artist.getTopTags", ["artist": artist, "autocorrect": "1"]),
              let list = (r["toptags"] as? [String: Any])?["tag"] as? [[String: Any]] else { return [] }
        return list.prefix(12).compactMap { ($0["name"] as? String)?.lowercased() }
    }

    // MARK: The user's listening (needs the connected account)

    struct Top: Identifiable, Hashable {
        let name: String
        let artist: String
        let plays: Int
        let image: URL?
        var id: String { artist + "|" + name }
    }

    /// period: 7day, 1month, 3month, 6month, 12month, overall. kind: artists, albums, tracks.
    func userTop(_ kind: String, period: String, limit: Int = 10) async -> [Top] {
        guard Self.hasKey, !Self.userName.isEmpty,
              let r = try? await call("user.getTop" + kind.prefix(1).uppercased() + kind.dropFirst(),
                                     ["user": Self.userName, "period": period, "limit": "\(limit)"]) else { return [] }
        let root = r["top" + kind] as? [String: Any]
        let list = root?[String(kind.dropLast())] as? [[String: Any]] ?? []
        return list.compactMap { o in
            guard let name = o["name"] as? String else { return nil }
            let artist = (o["artist"] as? [String: Any])?["name"] as? String ?? (kind == "artists" ? name : "")
            let image = (o["image"] as? [[String: Any]])?.last.flatMap { $0["#text"] as? String }.flatMap { $0.isEmpty ? nil : URL(string: $0) }
            return Top(name: name, artist: artist, plays: Int(o["playcount"] as? String ?? "") ?? 0, image: image)
        }
    }

    /// Number of scrobbles since a date, and in total.
    func scrobbles(since: Date?) async -> Int? {
        guard Self.hasKey, !Self.userName.isEmpty else { return nil }
        var p = ["user": Self.userName, "limit": "1"]
        if let since { p["from"] = "\(Int(since.timeIntervalSince1970))" }
        guard let r = try? await call("user.getRecentTracks", p),
              let attr = (r["recenttracks"] as? [String: Any])?["@attr"] as? [String: Any] else { return nil }
        return Int(attr["total"] as? String ?? "")
    }

    private var topCache: [String: [String]] = [:]

    /// The artist's most played tracks on Last.fm, as normalized names.
    func topTracks(_ artist: String) async -> Set<String> {
        Set(await topTrackNames(artist).prefix(10))
    }

    /// The same, in Last.fm's order (most played first), up to 30.
    func topTrackNames(_ artist: String) async -> [String] {
        let key = artist.lowercased()
        if let c = topCache[key] { return c }
        guard Self.hasKey,
              let r = try? await call("artist.getTopTracks", ["artist": artist, "autocorrect": "1", "limit": "30"]),
              let list = (r["toptracks"] as? [String: Any])?["track"] as? [[String: Any]] else { return [] }
        let names = list.compactMap { $0["name"] as? String }.map(Self.normalize)
        topCache[key] = names
        return names
    }

    /// "Song (2011 Remaster)" → "song": for matching track names across services.
    nonisolated static func normalize(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+-\s+.*(remaster|version|mix|edit|live).*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Last.fm summaries are HTML ending with a "Read more on Last.fm" link.
    nonisolated static func plainText(_ html: String) -> String {
        var s = html
        if let r = s.range(of: "<a href") { s = String(s[..<r.lowerBound]) }
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (e, c) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")] {
            s = s.replacingOccurrences(of: e, with: c)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: API

    enum LastFMError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return "Last.fm: \(m)" }; return nil }
    }

    /// api_sig: md5 of the parameters sorted by name, name+value concatenated, plus the secret.
    nonisolated static func signature(_ params: [String: String], secret: String) -> String {
        let s = params.filter { $0.key != "format" && $0.key != "callback" }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined() + secret
        return Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func call(_ method: String, _ params: [String: String] = [:], signed: Bool = false, post: Bool = false) async throws -> [String: Any] {
        var p = params
        p["method"] = method
        p["api_key"] = Self.apiKey
        if signed {
            if !Self.sessionKey.isEmpty && method != "auth.getToken" && method != "auth.getSession" { p["sk"] = Self.sessionKey }
            p["api_sig"] = Self.signature(p, secret: Self.secret)
        }
        p["format"] = "json"
        let body = p.map { "\(Self.encode($0.key))=\(Self.encode($0.value))" }.joined(separator: "&")
        var r: URLRequest
        if post {
            r = URLRequest(url: URL(string: "https://ws.audioscrobbler.com/2.0/")!)
            r.httpMethod = "POST"
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(body.utf8)
        } else {
            r = URLRequest(url: URL(string: "https://ws.audioscrobbler.com/2.0/?" + body)!)
        }
        r.timeoutInterval = 15
        r.setValue("KlangPlayer (https://github.com/satsura/klang-player)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: r)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LastFMError.message("bad response") }
        if json["error"] != nil { throw LastFMError.message(json["message"] as? String ?? "error") }
        return json
    }

    nonisolated static func encode(_ s: String) -> String {
        // ASCII only: CharacterSet.alphanumerics would leave Cyrillic letters unencoded.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
