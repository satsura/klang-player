import Foundation

/// SSDP search for UPnP MediaRenderers on the local network.
enum Discovery {
    static func speakers(timeout: Double = 3) async -> [SpeakerProfile] {
        if ProcessInfo.processInfo.environment["KLANG_NO_SSDP"] != nil { return [] } // debug: test the fallback
        let locations = await withCheckedContinuation { (cont: CheckedContinuation<[String: String], Never>) in
            DispatchQueue.global().async { cont.resume(returning: search(timeout: timeout)) }
        }
        var out: [SpeakerProfile] = []
        await withTaskGroup(of: SpeakerProfile?.self) { g in
            for (ip, loc) in locations {
                g.addTask {
                    guard let u = URL(string: loc),
                          let (data, _) = try? await URLSession.shared.data(from: u) else { return nil }
                    return await complete(ip: ip, location: u, data: data)
                }
            }
            for await p in g { if let p { out.append(p) } }
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func complete(ip: String, location: URL, data: Data) async -> SpeakerProfile? {
        guard var p = profile(ip: ip, location: location, xml: String(decoding: data, as: UTF8.self)) else { return nil }
        p.location = location.absoluteString
        p.sinks = await Speaker.shared.sinks(of: p)
        if p.kind == .frontier, p.sinks.isEmpty { p.sinks = ["audio/mpeg", "audio/mp4"] }
        return p
    }

    /// Fallback when SSDP is blocked or silent: asks every address of the /24 subnet for the
    /// same description URL (port + path) and returns the device with this UDN.
    static func scan(for known: SpeakerProfile) async -> SpeakerProfile? {
        guard !known.udn.isEmpty, let loc = known.location, let u = URL(string: loc),
              let port = u.port, let mine = localIP(toward: known.ip) else {
            debugLog("scan: skipped (udn \(known.udn), location \(known.location ?? "-"))")
            return nil
        }
        debugLog("scan: \(mine) port \(port) path \(u.path)")
        let prefix = mine.split(separator: ".").dropLast().joined(separator: ".")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.2
        let session = URLSession(configuration: cfg)
        return await withTaskGroup(of: SpeakerProfile?.self) { g in
            for host in 1...254 {
                let ip = "\(prefix).\(host)"
                guard ip != mine, let url = URL(string: "http://\(ip):\(port)\(u.path)") else { continue }
                g.addTask {
                    guard let (data, _) = try? await session.data(from: url),
                          String(decoding: data, as: UTF8.self).contains(known.udn) else { return nil }
                    return await complete(ip: ip, location: url, data: data)
                }
            }
            for await p in g { if let p { g.cancelAll(); return p } }
            return nil
        }
    }

    /// Builds a profile from a device description. Nil if it isn't a usable renderer.
    static func profile(ip: String, location: URL, xml: String) -> SpeakerProfile? {
        // Only the MediaRenderer device block (descriptions can nest several devices).
        guard let r = xml.range(of: "urn:schemas-upnp-org:device:MediaRenderer:1") else { return nil }
        var block = String(xml[r.upperBound...])
        if let next = block.range(of: "<deviceType>") { block = String(block[..<next.lowerBound]) }
        let head = String(xml[..<r.lowerBound])
        let name = xmlUnescape(lastValue(head, "friendlyName") ?? xmlValue(block, "friendlyName") ?? ip)
        let maker = xmlUnescape(lastValue(head, "manufacturer") ?? xmlValue(block, "manufacturer") ?? "")
        let udn = (xmlValue(block, "UDN") ?? lastValue(head, "UDN") ?? "").replacingOccurrences(of: "uuid:", with: "")

        var base = xmlValue(xml, "URLBase") ?? ""
        if base.isEmpty, let scheme = location.scheme, let host = location.host {
            base = "\(scheme)://\(host)\(location.port.map { ":\($0)" } ?? "")"
        }
        func absolute(_ path: String) -> String {
            if path.hasPrefix("http") { return path }
            let b = base.hasSuffix("/") ? String(base.dropLast()) : base
            return b + (path.hasPrefix("/") ? path : "/" + path)
        }
        var controls: [String: String] = [:]
        for svc in block.components(separatedBy: "<service>").dropFirst() {
            guard let type = xmlValue(svc, "serviceType"), let ctl = xmlValue(svc, "controlURL") else { continue }
            for s in ["AVTransport", "RenderingControl", "ConnectionManager"] where type.contains(":service:\(s):") {
                controls[s] = absolute(ctl)
            }
        }
        if let av = controls["AVTransport"] {
            return SpeakerProfile(ip: ip, name: name, manufacturer: maker, udn: udn, kind: .upnp, avControl: av,
                                  rcControl: controls["RenderingControl"], cmControl: controls["ConnectionManager"])
        }
        // Frontier Silicon: services exist but aren't listed.
        if xml.contains("frontier-silicon") || xml.contains("undok") {
            return .frontier(ip: ip, name: name, udn: udn, manufacturer: maker)
        }
        return nil
    }

    private static func lastValue(_ xml: String, _ tag: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>", options: .backwards),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    /// Returns ip → description URL.
    private static func search(timeout: Double) -> [String: String] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")
        // Some speakers only answer for the service type, so ask for both.
        for st in ["urn:schemas-upnp-org:device:MediaRenderer:1", "urn:schemas-upnp-org:service:AVTransport:1"] {
            let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(st)\r\n\r\n"
            let bytes = Array(msg.utf8)
            for _ in 0..<2 {
                let r = withUnsafePointer(to: &addr) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if r < 0 { debugLog("SSDP sendto failed: errno \(errno)") }
            }
        }

        var found: [String: String] = [:]
        var buf = [UInt8](repeating: 0, count: 4096)
        var packets = 0
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            packets += 1
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            let ip = String(cString: inet_ntoa(from.sin_addr))
            for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                let loc = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                // Frontier speakers answer from two descriptions; keep the UPnP one (dd.xml).
                if found[ip] == nil || loc.hasSuffix("dd.xml") { found[ip] = loc }
            }
        }
        debugLog("SSDP: \(packets) replies, \(found.count) devices, errno \(errno)")
        return found
    }
}
