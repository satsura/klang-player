import Foundation

struct Renderer: Identifiable, Hashable {
    let ip: String
    let name: String
    let manufacturer: String
    var id: String { ip }
    /// Frontier Silicon based speakers (Loewe klang etc.) — the ones this app knows how to drive.
    var isSupported: Bool
}

/// SSDP search for UPnP MediaRenderers on the local network.
enum Discovery {
    static func renderers(timeout: Double = 3) async -> [Renderer] {
        let locations = await withCheckedContinuation { (cont: CheckedContinuation<[String: String], Never>) in
            DispatchQueue.global().async { cont.resume(returning: search(timeout: timeout)) }
        }
        var out: [Renderer] = []
        await withTaskGroup(of: Renderer?.self) { g in
            for (ip, loc) in locations {
                g.addTask {
                    guard let u = URL(string: loc),
                          let (data, _) = try? await URLSession.shared.data(from: u) else { return nil }
                    let x = String(decoding: data, as: UTF8.self)
                    let name = xmlValue(x, "friendlyName") ?? ip
                    let maker = xmlValue(x, "manufacturer") ?? ""
                    let fs = x.contains("frontier-silicon") || x.contains("undok") || maker.lowercased().contains("loewe")
                    return Renderer(ip: ip, name: name, manufacturer: maker, isSupported: fs)
                }
            }
            for await r in g { if let r { out.append(r) } }
        }
        return out.sorted { ($0.isSupported ? 0 : 1, $0.name) < ($1.isSupported ? 0 : 1, $1.name) }
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
                _ = withUnsafePointer(to: &addr) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var found: [String: String] = [:]
        var buf = [UInt8](repeating: 0, count: 4096)
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            let ip = String(cString: inet_ntoa(from.sin_addr))
            for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                let loc = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                // Frontier speakers answer from two descriptions; keep the UPnP one (dd.xml).
                if found[ip] == nil || loc.hasSuffix("dd.xml") { found[ip] = loc }
            }
        }
        return found
    }
}
