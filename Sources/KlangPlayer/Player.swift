import AppKit
import Foundation

@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    enum State { case idle, preparing, playing, paused }

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = -1
    @Published private(set) var state: State = .idle
    @Published var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var volume: Double = 0
    @Published private(set) var maxVolume: Double = 32
    @Published var status: String?
    /// "AAC 320" / "MP3 320" — what actually goes to the speaker.
    @Published private(set) var outputLabel: String?
    /// Progress of preparing the current track (download / conversion).
    @Published private(set) var preparePhase: PreparePhase?

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var upcoming: ArraySlice<Track> { index + 1 < queue.count ? queue[(index + 1)...] : [] }

    private var urls: [String: (url: String, mime: String)] = [:]
    private var generation = 0                   // bumps on every explicit track start
    private var polling = false
    private var scrubbing = false
    private var stoppedPolls = 0
    private var lastPosition: Double = 0
    private var activity: NSObjectProtocol?
    private var volumeTask: Task<Void, Never>?
    private var lastUserVolume = Date.distantPast
    private var volumeReading = false
    private var ticks = 0
    private var timer: Timer?

    private init() {
        FileServer.shared.start()
        Task {
            await Preparer.shared.setProgressHandler { id, phase in
                Task { @MainActor in
                    let p = Player.shared
                    if p.current?.Id == id, p.state == .preparing { p.preparePhase = phase }
                }
            }
        }
        Task { await Preparer.shared.trimCache() }
        Task { await refreshVolume() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.ticks += 1
                // Volume can change on the speaker itself (knob, remote, its app) — keep re-reading it.
                if self.ticks % 2 == 0 { await self.syncVolume() }
                await self.poll()
            }
        }
    }

    // MARK: Queue

    func play(_ tracks: [Track], at i: Int = 0) {
        guard tracks.indices.contains(i) else { return }
        queue = tracks
        Task { await startTrack(i) }
    }

    func playNext(_ tracks: [Track]) {
        guard current != nil else { play(tracks); return }
        queue.insert(contentsOf: tracks, at: index + 1)
        requeueNext()
    }

    func enqueue(_ tracks: [Track]) {
        guard current != nil else { play(tracks); return }
        let wasLast = index + 1 >= queue.count
        queue.append(contentsOf: tracks)
        if wasLast { requeueNext() }
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        Task { await startTrack(i) }
    }

    func remove(at i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        let wasNext = i == index + 1
        queue.remove(at: i)
        if i < index { index -= 1 }
        if wasNext { requeueNext() }
    }

    func clearUpcoming() {
        guard index + 1 < queue.count else { return }
        queue.removeSubrange((index + 1)...)
    }

    private func requeueNext() {
        let gen = generation
        Task { await queueNext(gen) }
    }

    // MARK: Transport

    func toggle() {
        switch state {
        case .playing:
            state = .paused
            Task { await run { try await Speaker.shared.pause() } }
            Reporter.shared.progress(position: position, paused: true, force: true)
            keepAwake(false)
        case .paused:
            state = .playing
            keepAwake(true)
            Task { await run { try await Speaker.shared.play() } }
            Reporter.shared.progress(position: position, paused: false, force: true)
        case .idle:
            if current != nil { Task { await startTrack(index) } }
        case .preparing:
            break
        }
    }

    func next() {
        guard index + 1 < queue.count else { return }
        Task { await startTrack(index + 1) }
    }

    func previous() {
        if position > 3 || index == 0 {
            seek(to: 0)
        } else {
            Task { await startTrack(index - 1) }
        }
    }

    func seek(to seconds: Double) {
        position = seconds
        Task { await run { try await Speaker.shared.seek(seconds) } }
    }

    func setScrubbing(_ on: Bool) { scrubbing = on }

    func stop() {
        generation += 1
        Reporter.shared.stopped(at: position)
        state = .idle
        keepAwake(false)
        Task { await run { try await Speaker.shared.stop() } }
    }

    /// Called only by user input (slider, scroll); sends the value to the speaker.
    func setVolume(_ value: Double) {
        let v = min(maxVolume, max(0, value.rounded()))
        volume = v
        lastUserVolume = Date()
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await run { try await Speaker.shared.setVolume(Int(v)) }
            lastUserVolume = Date()
        }
    }

    func refreshVolume() async {
        if let m = try? await Speaker.shared.maxVolume() { maxVolume = Double(m) }
        await syncVolume(force: true)
    }

    /// Reads the speaker volume unless the user is changing it right now.
    private func syncVolume(force: Bool = false) async {
        guard !volumeReading, force || Date().timeIntervalSince(lastUserVolume) > 2, Config.isConfigured else { return }
        volumeReading = true
        defer { volumeReading = false }
        guard let v = try? await Speaker.shared.volume(),
              force || Date().timeIntervalSince(lastUserVolume) > 2 else { return }
        if Double(v) != volume { volume = Double(v) }
    }

    // MARK: Playback

    private func startTrack(_ i: Int, retried: Bool = false) async {
        guard queue.indices.contains(i) else { return }
        generation += 1
        let gen = generation
        let previousPosition = position
        index = i
        state = .preparing
        preparePhase = nil
        position = 0
        lastPosition = 0
        stoppedPolls = 0
        duration = queue[i].duration
        status = nil
        let t = queue[i]
        do {
            let (url, mime) = try await urlFor(t)
            guard gen == generation else { return }
            try await Speaker.shared.ensureReady()
            try await Speaker.shared.setURI(url, meta: didl(t, url: url, mime: mime))
            try await Speaker.shared.play()
            guard gen == generation else { return }
            state = .playing
            preparePhase = nil
            outputLabel = label(mime)
            keepAwake(true)
            Reporter.shared.started(t, mime: mime, previousPosition: previousPosition)
            await queueNext(gen)
        } catch {
            guard gen == generation else { return }
            // Can't reach the speaker: it may have a new IP. Find it again by UDN and retry once.
            if !retried, error is URLError, await Player.relocateSpeaker() {
                urls = [:]
                await startTrack(i, retried: true)
                return
            }
            state = .idle
            status = error.localizedDescription
            keepAwake(false)
        }
    }

    /// Re-discovers speakers; updates the current one if its address or details changed.
    /// Returns true if the current speaker was found at a different address.
    @discardableResult
    static func relocateSpeaker() async -> Bool {
        let found = await Discovery.speakers()
        if !found.isEmpty { Config.knownSpeakers = found }
        guard let cur = Config.speaker else { return false }
        var match = found.first { !cur.udn.isEmpty && $0.udn == cur.udn }
            ?? found.first { $0.ip == cur.ip && $0.kind == cur.kind }
        // SSDP found nothing (e.g. no Local Network permission): ask the known address directly…
        if match == nil, let loc = cur.location ?? (cur.kind == .frontier ? "http://\(cur.ip):8080/dd.xml" : nil),
           let u = URL(string: loc), let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: u, timeoutInterval: 3)),
           let p = await Discovery.complete(ip: cur.ip, location: u, data: data), cur.udn.isEmpty || p.udn == cur.udn {
            match = p
        }
        // …and if it's not there any more, look for the same UDN across the subnet.
        if match == nil, !cur.udn.isEmpty {
            match = await Discovery.scan(for: cur)
        }
        debugLog("relocate: ssdp \(found.count), match \(match.map { "\($0.name)@\($0.ip)" } ?? "-"), current \(cur.ip)")
        guard let match, match != cur else { return false }
        Config.speaker = match
        return match.ip != cur.ip
    }

    /// Prepares the following track and hands it to the speaker for a gapless switch.
    private func queueNext(_ gen: Int) async {
        let ni = index + 1
        guard queue.indices.contains(ni) else { return }
        let t = queue[ni]
        guard let (url, mime) = try? await urlFor(t), gen == generation,
              queue.indices.contains(index + 1), queue[index + 1].Id == t.Id else { return }
        try? await Speaker.shared.setNext(url, meta: didl(t, url: url, mime: mime))
    }

    private func urlFor(_ t: Track) async throws -> (String, String) {
        if let u = urls[t.Id] { return (u.url, u.mime) }
        // Speakers that take FLAC get the original straight from Emby — no conversion, no Mac in the path.
        if let sp = Config.speaker, let flac = sp.flacMime, t.codec == "flac" {
            let u = Emby.shared.originalURL(t).absoluteString
            urls[t.Id] = (u, flac)
            return (u, flac)
        }
        let p = try await Preparer.shared.prepare(t)
        let url: String
        switch p.source {
        case .file(let f):
            guard let ip = localIP(toward: Config.speakerIP) else { throw PlayerError.noLocalIP }
            url = "http://\(ip):\(FileServer.shared.port)\(FileServer.shared.publish(f, mime: p.mime))"
        case .remote(let u):
            url = u.absoluteString
        }
        urls[t.Id] = (url, p.mime)
        return (url, p.mime)
    }

    private func label(_ mime: String) -> String {
        switch mime {
        case "audio/mp4": "AAC 320"
        case "audio/mpeg": "MP3 320"
        default: "FLAC"
        }
    }

    /// Switches playback to another speaker; continues the current track there.
    func useSpeaker(_ p: SpeakerProfile) {
        let old = Config.speaker
        guard old?.id != p.id || old?.ip != p.ip else { return }
        let resume = state == .playing ? position : nil
        Reporter.shared.stopped(at: position)
        generation += 1
        state = current == nil ? .idle : .paused
        keepAwake(false)
        Task {
            if let old { try? await Speaker.shared.stop(old) }
            Config.speaker = p
            Speaker.shared.resetModeCache()
            urls = [:] // formats differ between speakers
            await refreshVolume()
            if let resume, current != nil {
                await startTrack(index)
                if state == .playing, resume > 5 { seek(to: resume) }
            }
        }
    }

    private func poll() async {
        guard !polling, state == .playing || state == .paused else { return }
        polling = true
        defer { polling = false }
        let gen = generation
        guard let info = try? await Speaker.shared.positionInfo(),
              let ts = try? await Speaker.shared.transportState(),
              gen == generation, state == .playing || state == .paused else { return }

        // The speaker switched to the next track on its own (gapless).
        if index + 1 < queue.count, let nu = urls[queue[index + 1].Id], info.uri == nu.url {
            index += 1
            position = info.rel
            lastPosition = info.rel
            duration = queue[index].duration
            outputLabel = label(nu.mime)
            stoppedPolls = 0
            Reporter.shared.started(queue[index], mime: nu.mime, previousPosition: nil)
            await queueNext(generation)
            return
        }
        // Someone else took over the speaker (radio, Spotify, Bluetooth…).
        if !info.uri.isEmpty, let cur = current, info.uri != urls[cur.Id]?.url {
            Reporter.shared.stopped(at: position)
            state = .idle
            keepAwake(false)
            return
        }

        if !scrubbing { position = info.rel }
        if info.duration > 0 { duration = info.duration }

        switch ts {
        case "PLAYING":
            stoppedPolls = 0
            lastPosition = info.rel
            Reporter.shared.progress(position: info.rel, paused: false)
            if state != .playing { state = .playing; keepAwake(true) }
        case "PAUSED_PLAYBACK":
            if state != .paused { state = .paused; keepAwake(false) }
        case "STOPPED", "NO_MEDIA_PRESENT":
            guard state == .playing else { break }
            stoppedPolls += 1
            guard stoppedPolls >= 2 else { break }
            let nearEnd = duration > 0 && duration - lastPosition < 6
            if nearEnd && index + 1 < queue.count {
                await startTrack(index + 1)
            } else {
                Reporter.shared.stopped(at: nearEnd ? duration : lastPosition)
                state = .idle
                if nearEnd { position = 0 }
                keepAwake(false)
            }
        default:
            break
        }
    }

    private func run(_ op: () async throws -> Void) async {
        do { try await op() } catch { status = error.localizedDescription }
    }

    private func keepAwake(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: "Playing music on the speaker")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    private func didl(_ t: Track, url: String, mime: String) -> String {
        var art = ""
        if let img = Emby.shared.imageURL(itemId: t.AlbumId, tag: t.AlbumPrimaryImageTag, size: 500) {
            art = "<upnp:albumArtURI>\(xmlEscape(img.absoluteString))</upnp:albumArtURI>"
        }
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="\(t.Id)" parentID="0" restricted="1">\
        <dc:title>\(xmlEscape(t.Name))</dc:title><dc:creator>\(xmlEscape(t.artist))</dc:creator>\
        <upnp:artist>\(xmlEscape(t.artist))</upnp:artist><upnp:album>\(xmlEscape(t.Album ?? ""))</upnp:album>\(art)\
        <upnp:class>object.item.audioItem.musicTrack</upnp:class>\
        <res protocolInfo="http-get:*:\(mime):*" duration="\(hms(t.duration))">\(xmlEscape(url))</res></item></DIDL-Lite>
        """
    }

    /// Debug (--preview): shows a queue in the UI without touching the speaker.
    func preview(_ tracks: [Track]) {
        Speaker.dryRun = true
        generation += 1
        queue = tracks
        index = 0
        duration = tracks.first?.duration ?? 0
        position = duration * 0.3
        outputLabel = "AAC 320"
        state = .paused
    }

    // MARK: Self-test (KlangPlayer --selftest): plays the first tracks of an album briefly, then exits.

    func selfTest() async {
        func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        do {
            let albums = try await Emby.shared.albums()
            log("albums: \(albums.count)")
            let want = ProcessInfo.processInfo.environment["KLANG_ALBUM"] ?? ""
            guard let album = albums.first(where: { !want.isEmpty && $0.Name.contains(want) }) ?? albums.first else { exit(1) }
            let tracks = try await Emby.shared.tracks(album: album.Id)
            log("album: \(album.Name) — \(tracks.count) tracks, first: \(tracks.first?.Name ?? "-") \(tracks.first?.sourceLabel ?? "")")
            let savedSpeaker = Config.speaker
            if let want = ProcessInfo.processInfo.environment["KLANG_SPEAKER"] {
                guard let sp = await Discovery.speakers().first(where: { $0.ip == want || $0.name == want }) else { log("no speaker \(want)"); exit(1) }
                Config.speaker = sp
                log("speaker: \(sp.name) \(sp.kind.rawValue) \(sp.formatLabel)")
            }
            defer { Config.speaker = savedSpeaker }
            let vol = try await Speaker.shared.volume()
            if Config.speaker?.kind == .frontier { try await Speaker.shared.setVolume(10) }
            let t0 = Date()
            play(Array(tracks.prefix(3)), at: 0)
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                if state == .playing { break }
            }
            log(String(format: "started in %.1fs, state=\(state), out=\(outputLabel ?? "-"), status=\(status ?? "-")", Date().timeIntervalSince(t0)))
            try await Task.sleep(nanoseconds: 5_000_000_000)
            log("pos=\(position) dur=\(duration) idx=\(index) state=\(state)")
            next()
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                if index == 1, state == .playing { break }
            }
            try await Task.sleep(nanoseconds: 4_000_000_000)
            log("after next: idx=\(index) \(current?.Name ?? "-") pos=\(position) state=\(state) status=\(status ?? "-")")
            // Natural end of track: jump close to the end and wait for the speaker to switch on its own.
            seek(to: max(0, duration - 6))
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                if index == 2 { break }
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
            log("after track end: idx=\(index) \(current?.Name ?? "-") pos=\(position) state=\(state) status=\(status ?? "-")")
            stop()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if Config.speaker?.kind == .frontier { try await Speaker.shared.setVolume(vol) }
            Config.speaker = savedSpeaker
            log("stopped, volume \(vol)")
            exit(0)
        } catch {
            log("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }
}
