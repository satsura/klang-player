import Foundation

/// Preparation phase, reported to the UI.
enum PreparePhase: Equatable {
    case downloading(Double)
    case converting
}

typealias PrepareProgress = @Sendable (_ trackId: String, _ phase: PreparePhase) -> Void

/// What the speaker should fetch for a track.
struct Prepared {
    enum Source { case file(URL), remote(URL) }
    let source: Source
    let mime: String
}

/// Downloads the original from Emby and converts it to AAC 320 (.m4a, moov first)
/// with Apple's encoder. The speaker only plays AAC as a complete file, not as a stream.
actor Preparer {
    static let shared = Preparer()

    let dir: URL
    private var tasks: [String: Task<Prepared, Error>] = [:]
    /// Set by the player; receives progress for every track being prepared.
    var onProgress: PrepareProgress?

    func setProgressHandler(_ h: @escaping PrepareProgress) { onProgress = h }

    init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KlangPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func prepare(_ t: Track) async throws -> Prepared {
        if let task = tasks[t.Id] {
            // The file may have been trimmed from the cache since: prepare it again.
            if let p = try? await task.value, case .file(let f) = p.source, !FileManager.default.fileExists(atPath: f.path) {
                tasks[t.Id] = nil
            } else {
                return try await task.value
            }
        }
        let dir = self.dir
        let progress = onProgress
        let task = Task { try await Preparer.make(t, dir: dir) { progress?(t.Id, $0) } }
        tasks[t.Id] = task
        do {
            let p = try await task.value
            // The MP3 stream is a fallback after a failed conversion: try converting again next time.
            if case .remote = p.source { tasks[t.Id] = nil }
            return p
        } catch {
            tasks[t.Id] = nil
            throw error
        }
    }

    private static func make(_ t: Track, dir: URL, progress: @escaping @Sendable (PreparePhase) -> Void) async throws -> Prepared {
        let fm = FileManager.default

        if t.codec == "mp3" {
            let out = dir.appendingPathComponent("\(t.Id).mp3")
            if !fm.fileExists(atPath: out.path) { try await download(Emby.shared.originalURL(t), to: out, progress: progress) }
            touch(out)
            return Prepared(source: .file(out), mime: "audio/mpeg")
        }

        // Normalized files get their own name, so turning the setting on or off converts again.
        let normalize = Config.normalizeLoudness
        let out = dir.appendingPathComponent(normalize ? "\(t.Id)-n.m4a" : "\(t.Id).m4a")
        if fm.fileExists(atPath: out.path) {
            touch(out)
            return Prepared(source: .file(out), mime: "audio/mp4")
        }

        let src = dir.appendingPathComponent("\(t.Id).src.\(t.container)")
        let part = dir.appendingPathComponent("\(t.Id).part.m4a")
        let leveled = dir.appendingPathComponent("\(t.Id).src.wav")
        defer {
            try? fm.removeItem(at: src)
            try? fm.removeItem(at: part)
            try? fm.removeItem(at: leveled)
        }
        try await download(Emby.shared.originalURL(t), to: src, progress: progress)
        progress(.converting)

        // Loudness: measure (EBU R128) and level to the target before encoding.
        var input = src
        if normalize, let r = try? Loudness.measure(src), abs(r.gainDB) >= 0.5,
           (try? Loudness.apply(r.gainDB, from: src, to: leveled)) != nil {
            debugLog(String(format: "loudness %@: %.1f LUFS, gain %+.1f dB", t.Name, r.lufs, r.gainDB))
            input = leveled
        }

        var format = "aac"
        if let sr = t.sampleRate, sr > 48_000 {
            format = "aac@\(sr % 44_100 == 0 ? 44_100 : 48_000)"
        }
        let ok = await run("/usr/bin/afconvert", [
            "-f", "m4af", "-d", format, "-b", "\(Config.aacBitrate)", "-q", "127", "-s", "0",
            input.path, part.path,
        ])
        if ok, fm.fileExists(atPath: part.path) {
            try? fm.removeItem(at: out)
            try fm.moveItem(at: part, to: out)
            return Prepared(source: .file(out), mime: "audio/mp4")
        }
        // Couldn't convert locally: let Emby stream MP3 320 (the speaker plays live MP3).
        return Prepared(source: .remote(Emby.shared.mp3URL(t)), mime: "audio/mpeg")
    }

    private static func download(_ url: URL, to dest: URL, progress: @escaping @Sendable (PreparePhase) -> Void) async throws {
        progress(.downloading(0))
        let (tmp, resp) = try await URLSession.shared.download(from: url, delegate: DownloadProgress { progress(.downloading($0)) })
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw PlayerError.http(code)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    private static func run(_ exe: String, _ args: [String]) async -> Bool {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus == 0) }
            do { try p.run() } catch { cont.resume(returning: false) }
        }
    }

    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Removes the oldest converted files above the cache limit.
    func trimCache(keep: Set<String> = []) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var items: [(url: URL, size: Int64, date: Date)] = files.compactMap {
            guard let v = try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return ($0, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        // Leftovers from an interrupted conversion (old ones only: a conversion may be running now).
        let partial = { (u: URL) in u.lastPathComponent.contains(".part.") || u.lastPathComponent.contains(".src.") }
        for i in items where partial(i.url) && i.date < Date().addingTimeInterval(-3600) {
            try? fm.removeItem(at: i.url)
        }
        items.removeAll { partial($0.url) }
        var total = items.reduce(0) { $0 + $1.size }
        let removable = items.filter {
            !keep.contains($0.url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-n", with: ""))
        }
        for i in removable.sorted(by: { $0.date < $1.date }) where total > Config.cacheLimitBytes {
            try? fm.removeItem(at: i.url)
            total -= i.size
        }
    }
}

/// Reports download progress of the task it's attached to.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?
    private var last = -1.0

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            guard let self else { return }
            let v = (p.fractionCompleted * 100).rounded() / 100
            if v != self.last { self.last = v; self.report(v) }
        }
    }
}
