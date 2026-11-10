import Foundation

struct PositionInfo {
    let rel: Double
    let duration: Double
    let uri: String
}

/// A network speaker (UPnP MediaRenderer) and how to drive it.
struct SpeakerProfile: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        /// Frontier Silicon (Loewe klang…): description lists no services, control URLs are fixed,
        /// volume and power via fsapi. Plays MP3/AAC only.
        case frontier
        /// Standard UPnP renderer (Marantz/Denon HEOS…): URLs from the description, volume via RenderingControl.
        case upnp
    }

    var ip: String
    var name: String
    var manufacturer = ""
    var udn = ""
    var kind: Kind
    var avControl: String
    var rcControl: String?
    var cmControl: String?
    /// MIME types the renderer accepts (ConnectionManager sinks).
    var sinks: [String] = []
    /// Device description URL; its port and path are reused to find the speaker at a new IP.
    var location: String? = nil

    var id: String { udn.isEmpty ? ip : udn }

    var supportsFLAC: Bool { flacMime != nil }
    var flacMime: String? { sinks.first { $0 == "audio/flac" || $0 == "audio/x-flac" } }
    /// What tracks become on this speaker.
    var formatLabel: String { supportsFLAC ? "FLAC" : "AAC 320" }

    static func frontier(ip: String, name: String = "", udn: String = "", manufacturer: String = "") -> SpeakerProfile {
        SpeakerProfile(ip: ip, name: name.isEmpty ? ip : name, manufacturer: manufacturer, udn: udn, kind: .frontier,
                       avControl: "http://\(ip):8080/AVTransport/control",
                       rcControl: "http://\(ip):8080/RenderingControl/control",
                       cmControl: "http://\(ip):8080/ConnectionManager/control",
                       sinks: ["audio/mpeg", "audio/mp4"],
                       location: "http://\(ip):8080/dd.xml")
    }
}

/// Talks to the selected speaker (Config.speaker).
final class Speaker {
    static let shared = Speaker()

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.httpMaximumConnectionsPerHost = 1 // Frontier speakers stall on parallel requests
        return URLSession(configuration: c)
    }()

    private var profile: SpeakerProfile? { Config.speaker }
    /// Debug preview: only reads are allowed, nothing that changes what the speaker does.
    static var dryRun = false
    private var mpModeKey: String?

    // MARK: UPnP

    @discardableResult
    private func soap(_ service: String, _ action: String, _ args: String = "", instance: Bool = true,
                      to p: SpeakerProfile? = nil) async throws -> String {
        guard let p = p ?? profile else { throw PlayerError.notConfigured }
        if Speaker.dryRun, !action.hasPrefix("Get") { throw PlayerError.speaker("dry run: \(action)") }
        let control: String? = switch service {
        case "AVTransport": p.avControl
        case "RenderingControl": p.rcControl
        default: p.cmControl
        }
        guard let control, let url = URL(string: control) else { throw PlayerError.speaker("\(service): no control URL") }
        let ns = "urn:schemas-upnp-org:service:\(service):1"
        let body = """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(ns)">\
        \(instance ? "<InstanceID>0</InstanceID>" : "")\(args)</u:\(action)></s:Body></s:Envelope>
        """
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        r.setValue("\"\(ns)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        r.httpBody = Data(body.utf8)
        let (data, resp) = try await session.data(for: r)
        let s = String(decoding: data, as: UTF8.self)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let code = xmlValue(s, "errorCode") ?? "?"
            let desc = xmlValue(s, "errorDescription") ?? ""
            throw PlayerError.speaker("\(action): \(code) \(desc)")
        }
        return s
    }

    func setURI(_ url: String, meta: String) async throws {
        try await soap("AVTransport", "SetAVTransportURI",
                       "<CurrentURI>\(xmlEscape(url))</CurrentURI><CurrentURIMetaData>\(xmlEscape(meta))</CurrentURIMetaData>")
    }

    func setNext(_ url: String, meta: String) async throws {
        try await soap("AVTransport", "SetNextAVTransportURI",
                       "<NextURI>\(xmlEscape(url))</NextURI><NextURIMetaData>\(xmlEscape(meta))</NextURIMetaData>")
    }

    func play() async throws { try await soap("AVTransport", "Play", "<Speed>1</Speed>") }
    func pause() async throws { try await soap("AVTransport", "Pause") }
    func stop(_ p: SpeakerProfile? = nil) async throws { try await soap("AVTransport", "Stop", to: p) }

    func seek(_ seconds: Double) async throws {
        try await soap("AVTransport", "Seek", "<Unit>REL_TIME</Unit><Target>\(hms(seconds))</Target>")
    }

    func transportState() async throws -> String {
        xmlValue(try await soap("AVTransport", "GetTransportInfo"), "CurrentTransportState") ?? ""
    }

    func positionInfo() async throws -> PositionInfo {
        let s = try await soap("AVTransport", "GetPositionInfo")
        return PositionInfo(rel: parseHMS(xmlValue(s, "RelTime") ?? ""),
                            duration: parseHMS(xmlValue(s, "TrackDuration") ?? ""),
                            uri: xmlUnescape(xmlValue(s, "TrackURI") ?? ""))
    }

    /// MIME types the renderer accepts.
    func sinks(of p: SpeakerProfile) async -> [String] {
        guard let s = try? await soap("ConnectionManager", "GetProtocolInfo", instance: false, to: p),
              let sink = xmlValue(s, "Sink") else { return [] }
        let mimes = xmlUnescape(sink).split(separator: ",").compactMap { entry -> String? in
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { return nil }
            return String(parts[2].split(separator: ";").first ?? "").lowercased()
        }
        return Array(Set(mimes)).sorted()
    }

    // MARK: Volume

    func volume() async throws -> Int {
        guard let p = profile else { throw PlayerError.notConfigured }
        if p.kind == .frontier { return try await fsInt("netRemote.sys.audio.volume") }
        let s = try await soap("RenderingControl", "GetVolume", "<Channel>Master</Channel>")
        return Int(xmlValue(s, "CurrentVolume") ?? "") ?? 0
    }

    func maxVolume() async throws -> Int {
        guard let p = profile else { throw PlayerError.notConfigured }
        if p.kind == .frontier { return max(1, try await fsInt("netRemote.sys.caps.volumeSteps") - 1) }
        return 100
    }

    func setVolume(_ v: Int) async throws {
        guard let p = profile else { throw PlayerError.notConfigured }
        if p.kind == .frontier {
            _ = try await fs("SET", "netRemote.sys.audio.volume", value: "\(v)")
        } else {
            try await soap("RenderingControl", "SetVolume", "<Channel>Master</Channel><DesiredVolume>\(v)</DesiredVolume>")
        }
    }

    func setMute(_ on: Bool) async throws {
        try await soap("RenderingControl", "SetMute", "<Channel>Master</Channel><DesiredMute>\(on ? 1 : 0)</DesiredMute>")
    }

    // MARK: fsapi (Frontier only)

    private func fs(_ op: String, _ node: String, value: String? = nil, extra: String = "", query: String = "") async throws -> String {
        guard let p = profile, p.kind == .frontier else { throw PlayerError.notConfigured }
        if Speaker.dryRun, op == "SET" { throw PlayerError.speaker("dry run: \(node)") }
        var u = "http://\(p.ip)/fsapi/\(op)/\(node)\(extra)?pin=1234\(query)"
        if let value { u += "&value=\(value)" }
        let (data, _) = try await session.data(from: URL(string: u)!)
        let s = String(decoding: data, as: UTF8.self)
        guard xmlValue(s, "status") == "FS_OK" else { throw PlayerError.speaker("\(node): \(xmlValue(s, "status") ?? "?")") }
        return s
    }

    private func fsInt(_ node: String) async throws -> Int {
        let s = try await fs("GET", node)
        let v = xmlValue(s, "u8") ?? xmlValue(s, "u32") ?? xmlValue(s, "s8") ?? ""
        return Int(v) ?? 0
    }

    /// Frontier: wakes the speaker and switches it to "Music player" mode before network playback.
    func ensureReady() async throws {
        guard profile?.kind == .frontier else { return }
        if try await fsInt("netRemote.sys.power") == 0 {
            _ = try await fs("SET", "netRemote.sys.power", value: "1")
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if mpModeKey == nil {
            let list = try await fs("LIST_GET_NEXT", "netRemote.sys.caps.validModes", value: nil, extra: "/-1", query: "&maxItems=40")
            // <item key="8"><field name="id"><c8_array>MP</c8_array>
            for part in list.components(separatedBy: "<item key=\"").dropFirst() {
                let key = String(part.prefix { $0 != "\"" })
                if part.contains("<field name=\"id\"><c8_array>MP</c8_array>") { mpModeKey = key }
            }
        }
        if let mp = mpModeKey, String(try await fsInt("netRemote.sys.mode")) != mp {
            _ = try await fs("SET", "netRemote.sys.mode", value: mp)
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    func resetModeCache() { mpModeKey = nil }
}
