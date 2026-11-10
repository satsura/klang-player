import Foundation

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

    init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KlangPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func prepare(_ t: Track) async throws -> Prepared {
        if let task = tasks[t.Id] { return try await task.value }
        let dir = self.dir
        let task = Task { try await Preparer.make(t, dir: dir) }
        tasks[t.Id] = task
        do {
            return try await task.value
        } catch {
            tasks[t.Id] = nil
            throw error
        }
    }

    private static func make(_ t: Track, dir: URL) async throws -> Prepared {
        let fm = FileManager.default

        if t.codec == "mp3" {
            let out = dir.appendingPathComponent("\(t.Id).mp3")
            if !fm.fileExists(atPath: out.path) { try await download(Emby.shared.originalURL(t), to: out) }
            touch(out)
            return Prepared(source: .file(out), mime: "audio/mpeg")
        }

        let out = dir.appendingPathComponent("\(t.Id).m4a")
        if fm.fileExists(atPath: out.path) {
            touch(out)
            return Prepared(source: .file(out), mime: "audio/mp4")
        }

        let src = dir.appendingPathComponent("\(t.Id).src.\(t.container)")
        let part = dir.appendingPathComponent("\(t.Id).part.m4a")
        defer {
            try? fm.removeItem(at: src)
            try? fm.removeItem(at: part)
        }
        try await download(Emby.shared.originalURL(t), to: src)

        var format = "aac"
        if let sr = t.sampleRate, sr > 48_000 {
            format = "aac@\(sr % 44_100 == 0 ? 44_100 : 48_000)"
        }
        let ok = await run("/usr/bin/afconvert", [
            "-f", "m4af", "-d", format, "-b", "\(Config.aacBitrate)", "-q", "127", "-s", "0",
            src.path, part.path,
        ])
        if ok, fm.fileExists(atPath: part.path) {
            try? fm.removeItem(at: out)
            try fm.moveItem(at: part, to: out)
            return Prepared(source: .file(out), mime: "audio/mp4")
        }
        // Couldn't convert locally: let Emby stream MP3 320 (the speaker plays live MP3).
        return Prepared(source: .remote(Emby.shared.mp3URL(t)), mime: "audio/mpeg")
    }

    private static func download(_ url: URL, to dest: URL) async throws {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
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
    func trimCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var items: [(url: URL, size: Int64, date: Date)] = files.compactMap {
            guard let v = try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return ($0, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        // Leftovers from an interrupted conversion.
        for i in items where i.url.lastPathComponent.contains(".part.") || i.url.lastPathComponent.contains(".src.") {
            try? fm.removeItem(at: i.url)
        }
        items.removeAll { $0.url.lastPathComponent.contains(".part.") || $0.url.lastPathComponent.contains(".src.") }
        var total = items.reduce(0) { $0 + $1.size }
        for i in items.sorted(by: { $0.date < $1.date }) where total > Config.cacheLimitBytes {
            try? fm.removeItem(at: i.url)
            total -= i.size
        }
    }
}
