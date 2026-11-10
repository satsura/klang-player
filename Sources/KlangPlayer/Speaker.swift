import Foundation

struct PositionInfo {
    let rel: Double
    let duration: Double
    let uri: String
}

/// Loewe klang s3 (Frontier Silicon): UPnP AVTransport on :8080 + fsapi on :80.
/// Its device description lists no services, so control URLs are hardcoded.
final class Speaker {
    static let shared = Speaker()

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.httpMaximumConnectionsPerHost = 1 // the speaker stalls on parallel requests
        return URLSession(configuration: c)
    }()

    private var ip: String { Config.speakerIP }
    private var mpModeKey: String?

    // MARK: UPnP

    @discardableResult
    private func soap(_ service: String, _ action: String, _ args: String = "") async throws -> String {
        guard !ip.isEmpty else { throw PlayerError.notConfigured }
        let ns = "urn:schemas-upnp-org:service:\(service):1"
        let body = """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(ns)">\
        <InstanceID>0</InstanceID>\(args)</u:\(action)></s:Body></s:Envelope>
        """
        var r = URLRequest(url: URL(string: "http://\(ip):8080/\(service)/control")!)
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
    func stop() async throws { try await soap("AVTransport", "Stop") }

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

    // MARK: fsapi

    private func fs(_ op: String, _ node: String, value: String? = nil, extra: String = "", query: String = "") async throws -> String {
        guard !ip.isEmpty else { throw PlayerError.notConfigured }
        var u = "http://\(ip)/fsapi/\(op)/\(node)\(extra)?pin=1234\(query)"
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

    func volume() async throws -> Int { try await fsInt("netRemote.sys.audio.volume") }

    func maxVolume() async throws -> Int { max(1, try await fsInt("netRemote.sys.caps.volumeSteps") - 1) }

    func setVolume(_ v: Int) async throws { _ = try await fs("SET", "netRemote.sys.audio.volume", value: "\(v)") }

    /// Wakes the speaker and switches it to "Music player" mode before network playback.
    func ensureReady() async throws {
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
}
