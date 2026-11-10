import Foundation

/// Tells Emby what's playing (Sessions API): play history, play counts, "Now Playing" in the Emby
/// dashboard and Last.fm scrobbling through Emby's Last.fm plugin.
@MainActor
final class Reporter {
    static let shared = Reporter()

    private var current: (track: Track, session: String, method: String)?
    private var lastProgress = Date.distantPast

    private static func ticks(_ seconds: Double) -> Int64 { Int64(max(0, seconds) * 10_000_000) }

    /// A track started playing on the speaker.
    func started(_ t: Track, mime: String, previousPosition: Double?) {
        if let prev = current { stopped(at: previousPosition ?? prev.track.duration) }
        let method = (mime == "audio/mp4" || (mime == "audio/mpeg" && t.codec != "mp3")) ? "Transcode" : "DirectStream"
        let session = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        current = (t, session, method)
        lastProgress = Date()
        send("/Sessions/Playing", body(t, session: session, method: method, position: 0, paused: false))
    }

    /// Periodic position update; also sent right away on pause/resume.
    func progress(position: Double, paused: Bool, force: Bool = false) {
        guard let c = current, force || Date().timeIntervalSince(lastProgress) >= 10 else { return }
        lastProgress = Date()
        var b = body(c.track, session: c.session, method: c.method, position: position, paused: paused)
        b["EventName"] = force ? (paused ? "pause" : "unpause") : "timeupdate"
        send("/Sessions/Playing/Progress", b)
    }

    /// Playback of the current track ended (finished, skipped or stopped).
    func stopped(at position: Double) {
        guard let c = current else { return }
        current = nil
        send("/Sessions/Playing/Stopped", body(c.track, session: c.session, method: c.method, position: position, paused: false))
        // Signed in with an API key (no user session): Emby ignores the session reports for user data,
        // so mark the track played directly — same rule as scrobbling: half the track or 4 minutes.
        if Config.userName.isEmpty, position >= min(c.track.duration * 0.5, 240), position > 0 {
            markPlayed(c.track.Id)
        }
    }

    private func markPlayed(_ id: String) {
        guard !Speaker.dryRun else { return }
        // Emby wants yyyyMMddHHmmss in UTC here.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        let date = f.string(from: Date())
        var r = URLRequest(url: Emby.shared.url("/Users/\(Config.userId)/PlayedItems/\(id)", ["DatePlayed": date]))
        r.httpMethod = "POST"
        Task.detached {
            let code = ((try? await URLSession.shared.data(for: r))?.1 as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(code) { debugLog("mark played: HTTP \(code)") }
        }
    }

    private func body(_ t: Track, session: String, method: String, position: Double, paused: Bool) -> [String: Any] {
        [
            "ItemId": t.Id,
            "MediaSourceId": t.Id,
            "PlaySessionId": session,
            "PositionTicks": Reporter.ticks(position),
            "IsPaused": paused,
            "CanSeek": true,
            "PlayMethod": method,
            "QueueableMediaTypes": ["Audio"],
        ]
    }

    private func send(_ path: String, _ body: [String: Any]) {
        guard Config.isConfigured, !Speaker.dryRun else { return }
        var r = URLRequest(url: Emby.shared.url(path))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(Emby.shared.authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task.detached {
            let code = ((try? await URLSession.shared.data(for: r))?.1 as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(code) { debugLog("report \(path): HTTP \(code)") }
        }
    }
}
