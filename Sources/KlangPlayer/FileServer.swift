import Foundation
import Network

/// Minimal HTTP server with Range support: serves converted tracks to the speaker.
final class FileServer {
    static let shared = FileServer()

    private let q = DispatchQueue(label: "klang.fileserver")
    private var listener: NWListener?
    private var files: [String: (url: URL, mime: String)] = [:]
    private(set) var port: UInt16 = 0
    /// Local control API (/api/*), answered only for connections from this Mac. Called on the server queue.
    var api: ((_ method: String, _ path: String) -> (Int, String, Data))?

    func start() {
        guard listener == nil else { return }
        listen(on: 47830)
    }

    /// Fixed port first; if it's taken, any free port.
    private func listen(on port: NWEndpoint.Port?) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l: NWListener?
        if let port { l = try? NWListener(using: params, on: port) } else { l = try? NWListener(using: params) }
        guard let l else {
            if port != nil { listen(on: nil) }
            return
        }
        let sem = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = l.port?.rawValue ?? 0
                sem.signal()
            case .failed(let e):
                NSLog("KlangPlayer fileserver failed: \(e)")
                l.cancel()
                sem.signal()
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.start(queue: q)
        listener = l
        _ = sem.wait(timeout: .now() + 3)
        if self.port == 0 {
            listener = nil
            if port != nil { listen(on: nil) }
        }
    }

    /// Registers a file and returns its URL path.
    func publish(_ url: URL, mime: String) -> String {
        let path = "/t/" + url.lastPathComponent
        q.sync { files[path] = (url, mime) }
        return path
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: q)
        readHeader(c, Data())
    }

    private func readHeader(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buf
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(c, String(decoding: buf[..<end.lowerBound], as: UTF8.self))
            } else if done || err != nil || buf.count > 65_536 {
                c.cancel()
            } else {
                self.readHeader(c, buf)
            }
        }
    }

    private func respond(_ c: NWConnection, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let req = lines.first?.split(separator: " ") ?? []
        guard req.count >= 2 else { c.cancel(); return }
        let method = String(req[0])
        let path = String(req[1].split(separator: "?").first ?? "")
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }

        if path.hasPrefix("/api/") {
            var local = false
            if case .hostPort(let host, _) = c.endpoint {
                let h = "\(host)"
                local = h == "127.0.0.1" || h == "::1" || h.hasPrefix("::ffff:127.0.0.1")
            }
            guard local, let api else {
                send(c, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            }
            let (status, type, body) = api(method, path)
            let reason = [200: "OK", 204: "No Content", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
            var d = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
            d.append(body)
            c.send(content: d, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
            return
        }

        guard let entry = files[path],
              let attrs = try? FileManager.default.attributesOfItem(atPath: entry.url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0,
              let fh = try? FileHandle(forReadingFrom: entry.url)
        else {
            send(c, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }

        var start: Int64 = 0
        var end: Int64 = size - 1
        var partial = false
        if let r = headers["range"], r.hasPrefix("bytes=") {
            let spec = r.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
            let p = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if p.count == 2 {
                if p[0].isEmpty, let n = Int64(p[1]) {
                    start = max(0, size - n)
                } else {
                    start = Int64(p[0]) ?? 0
                    if let e = Int64(p[1]) { end = min(e, size - 1) }
                }
                partial = true
            }
        }
        guard start <= end else {
            try? fh.close()
            send(c, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }

        var h = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        h += "Content-Type: \(entry.mime)\r\n"
        h += "Content-Length: \(end - start + 1)\r\n"
        h += "Accept-Ranges: bytes\r\n"
        if partial { h += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        h += "transferMode.dlna.org: Streaming\r\n"
        h += "contentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n"
        h += "Connection: close\r\n\r\n"

        if method == "HEAD" {
            try? fh.close()
            send(c, h)
            return
        }
        c.send(content: Data(h.utf8), completion: .contentProcessed { [weak self] err in
            guard err == nil else { try? fh.close(); c.cancel(); return }
            try? fh.seek(toOffset: UInt64(start))
            self?.stream(c, fh, remaining: end - start + 1)
        })
    }

    private func stream(_ c: NWConnection, _ fh: FileHandle, remaining: Int64) {
        guard remaining > 0, let chunk = try? fh.read(upToCount: Int(min(262_144, remaining))), !chunk.isEmpty else {
            try? fh.close()
            c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
            return
        }
        c.send(content: chunk, completion: .contentProcessed { [weak self] err in
            guard err == nil else { try? fh.close(); c.cancel(); return }
            self?.stream(c, fh, remaining: remaining - Int64(chunk.count))
        })
    }

    private func send(_ c: NWConnection, _ s: String) {
        c.send(content: Data(s.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// IPv4 address of this Mac on the same subnet as `target`.
func localIP(toward target: String) -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    let t = inet_addr(target)
    var fallback: String?
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let a = p.pointee
        guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), let nm = a.ifa_netmask,
              a.ifa_flags & UInt32(IFF_LOOPBACK) == 0, a.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
        let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        let s = String(cString: inet_ntoa(in_addr(s_addr: ip)))
        if ip & mask == t & mask { return s }
        if fallback == nil { fallback = s }
    }
    return fallback
}
