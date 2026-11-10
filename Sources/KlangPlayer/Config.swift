import Foundation

enum Config {
    private static let d = UserDefaults.standard

    static var embyURL: String {
        get { d.string(forKey: "embyURL") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "embyURL") }
    }

    /// Emby access token (from login) or an API key.
    static var apiKey: String {
        get { d.string(forKey: "apiKey") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "apiKey") }
    }

    static var userId: String {
        get { d.string(forKey: "userId") ?? "" }
        set { d.set(newValue, forKey: "userId") }
    }

    static var userName: String {
        get { d.string(forKey: "userName") ?? "" }
        set { d.set(newValue, forKey: "userName") }
    }

    static var speakerIP: String {
        get { d.string(forKey: "speakerIP") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "speakerIP") }
    }

    static var speakerName: String {
        get { d.string(forKey: "speakerName") ?? "" }
        set { d.set(newValue, forKey: "speakerName") }
    }

    static var deviceId: String {
        if let id = d.string(forKey: "deviceId") { return id }
        let id = UUID().uuidString
        d.set(id, forKey: "deviceId")
        return id
    }

    static var isConfigured: Bool { !embyURL.isEmpty && !apiKey.isEmpty && !speakerIP.isEmpty }

    /// Cache limit for converted tracks.
    static let cacheLimitBytes: Int64 = 3 * 1024 * 1024 * 1024
    static let aacBitrate = 320_000
}

enum PlayerError: LocalizedError {
    case http(Int)
    case speaker(String)
    case noLocalIP
    case notConfigured
    case login(String)

    var errorDescription: String? {
        switch self {
        case .http(let c): return "Emby ответил \(c)"
        case .speaker(let s): return "Колонка: \(s)"
        case .noLocalIP: return "Не найден IP Mac в сети колонки"
        case .notConfigured: return "Укажи сервер Emby и колонку в настройках"
        case .login(let s): return s
        }
    }
}

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

func xmlUnescape(_ s: String) -> String {
    s.replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
}

func xmlValue(_ xml: String, _ tag: String) -> String? {
    guard let open = xml.range(of: "<\(tag)>"),
          let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else { return nil }
    return String(xml[open.upperBound..<close.lowerBound])
}

func hms(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}

func parseHMS(_ s: String) -> Double {
    let parts = s.split(separator: ":").map { Double($0) ?? 0 }
    return parts.reduce(0) { $0 * 60 + $1 }
}

func mmss(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

func totalDuration(_ tracks: [Track]) -> String {
    let m = Int(tracks.reduce(0) { $0 + $1.duration } / 60)
    return m >= 60 ? "\(m / 60) ч \(m % 60) мин" : "\(m) мин"
}
