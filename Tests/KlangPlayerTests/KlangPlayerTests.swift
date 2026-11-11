import XCTest
@testable import KlangPlayer

final class XMLAndTimeTests: XCTestCase {
    func testEscapeRoundTrip() {
        let s = #"Tom & Jerry <"live"> 'remix'"#
        XCTAssertEqual(xmlUnescape(xmlEscape(s)), s)
        XCTAssertFalse(xmlEscape(s).contains("<"))
    }

    func testXMLValue() {
        let x = "<a><RelTime>0:01:02</RelTime><TrackURI>http://x/t?a=1&amp;b=2</TrackURI></a>"
        XCTAssertEqual(xmlValue(x, "RelTime"), "0:01:02")
        XCTAssertEqual(xmlUnescape(xmlValue(x, "TrackURI") ?? ""), "http://x/t?a=1&b=2")
        XCTAssertNil(xmlValue(x, "Missing"))
    }

    func testTimeFormats() {
        XCTAssertEqual(parseHMS("01:02:03"), 3723)
        XCTAssertEqual(parseHMS("00:05:30"), 330)
        XCTAssertEqual(hms(3723.9), "1:02:03")
        XCTAssertEqual(mmss(65), "1:05")
        XCTAssertEqual(mmss(3725), "1:02:05")
        XCTAssertEqual(mmss(-3), "0:00")
    }
}

final class LibraryTests: XCTestCase {
    func testArtistKeyMergesSpellings() {
        XCTAssertEqual(Library.artistKey("Angus&Julia Stone"), Library.artistKey("Angus & Julia Stone"))
        XCTAssertEqual(Library.artistKey("  angus  &   julia stone "), Library.artistKey("Angus & Julia Stone"))
        XCTAssertNotEqual(Library.artistKey("Angus Stone"), Library.artistKey("Angus & Julia Stone"))
    }

    private func album(_ id: String, _ name: String, _ artist: String, cover: Bool = false) -> Album {
        Album(Id: id, Name: name, AlbumArtist: artist, ProductionYear: 2001, ImageTags: cover ? ["Primary": "t"] : nil)
    }

    func testCompilationIsMerged() {
        let albums = [
            album("1", "Comp", "A"), album("2", "Comp", "B", cover: true), album("3", "Comp", "C"),
            album("4", "Solo", "D"),
        ]
        let merged = Album.mergeCompilations(albums)
        XCTAssertEqual(merged.count, 2)
        let comp = merged.first { $0.Name == "Comp" }
        XCTAssertEqual(comp?.parts?.count, 3)
        XCTAssertEqual(comp?.imageItemId, "2", "cover comes from the part that has one")
        XCTAssertNil(merged.first { $0.Name == "Solo" }?.parts)
    }

    func testTwoArtistsAreNotACompilation() {
        let merged = Album.mergeCompilations([album("1", "X", "A"), album("2", "X", "B")])
        XCTAssertEqual(merged.count, 2)
    }
}

final class DiscoveryTests: XCTestCase {
    /// Loewe klang s3: MediaRenderer without a serviceList.
    let loewe = """
    <?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:fsns="urn:schemas-frontier-silicon-com:ir-1-0">
    <device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Loewe klang s3</friendlyName><manufacturer>Loewe</manufacturer>
    <UDN>uuid:3DCC7100-F76C-11DD-87AF-305890539A29</UDN><netRemoteVendorId>undok</netRemoteVendorId></device></root>
    """

    /// Marantz: renderer nested in a root device, relative control URLs.
    let marantz = """
    <root><device><deviceType>urn:schemas-denon-com:device:AiosDevice:1</deviceType>
    <friendlyName>Living Room</friendlyName><manufacturer>Marantz</manufacturer><deviceList>
    <device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><UDN>uuid:abc-123</UDN><serviceList>
    <service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/upnp/control/renderer_dvc/AVTransport</controlURL></service>
    <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>/upnp/control/renderer_dvc/ConnectionManager</controlURL></service>
    <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/upnp/control/renderer_dvc/RenderingControl</controlURL></service>
    </serviceList></device>
    <device><deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType><serviceList>
    <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>/upnp/control/ams_dvc/ConnectionManager</controlURL></service>
    </serviceList></device></deviceList></device></root>
    """

    func testFrontierProfile() throws {
        let p = try XCTUnwrap(Discovery.profile(ip: "10.0.0.5", location: URL(string: "http://10.0.0.5:8080/dd.xml")!, xml: loewe))
        XCTAssertEqual(p.kind, .frontier)
        XCTAssertEqual(p.name, "Loewe klang s3")
        XCTAssertEqual(p.udn, "3DCC7100-F76C-11DD-87AF-305890539A29")
        XCTAssertEqual(p.avControl, "http://10.0.0.5:8080/AVTransport/control")
        XCTAssertFalse(p.supportsFLAC)
        XCTAssertEqual(p.formatLabel, "AAC 320")
    }

    func testUPnPProfileUsesRendererServices() throws {
        let loc = URL(string: "http://10.0.0.12:60006/upnp/desc/aios_device/aios_device.xml")!
        var p = try XCTUnwrap(Discovery.profile(ip: "10.0.0.12", location: loc, xml: marantz))
        XCTAssertEqual(p.kind, .upnp)
        XCTAssertEqual(p.name, "Living Room")
        XCTAssertEqual(p.manufacturer, "Marantz")
        XCTAssertEqual(p.udn, "abc-123")
        XCTAssertEqual(p.avControl, "http://10.0.0.12:60006/upnp/control/renderer_dvc/AVTransport")
        XCTAssertEqual(p.cmControl, "http://10.0.0.12:60006/upnp/control/renderer_dvc/ConnectionManager",
                       "the renderer's ConnectionManager, not the media server's")
        p.sinks = ["audio/mpeg", "audio/flac"]
        XCTAssertEqual(p.flacMime, "audio/flac")
        XCTAssertEqual(p.formatLabel, "FLAC")
    }

    func testNotARenderer() {
        XCTAssertNil(Discovery.profile(ip: "1.2.3.4", location: URL(string: "http://1.2.3.4/d.xml")!,
                                       xml: "<root><device><deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType></device></root>"))
    }
}

final class FileServerTests: XCTestCase {
    func testRangeRequests() async throws {
        let server = FileServer()
        server.start()
        let port = server.port
        XCTAssertNotEqual(port, 0)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("klang-test-\(UUID().uuidString).m4a")
        let bytes = Data((0..<1000).map { UInt8($0 % 256) })
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let path = server.publish(file, mime: "audio/mp4")
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!

        let (full, r1) = try await URLSession.shared.data(from: url)
        let h1 = try XCTUnwrap(r1 as? HTTPURLResponse)
        XCTAssertEqual(h1.statusCode, 200)
        XCTAssertEqual(h1.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
        XCTAssertEqual(full, bytes)

        var req = URLRequest(url: url)
        req.setValue("bytes=100-199", forHTTPHeaderField: "Range")
        let (part, r2) = try await URLSession.shared.data(for: req)
        let h2 = try XCTUnwrap(r2 as? HTTPURLResponse)
        XCTAssertEqual(h2.statusCode, 206)
        XCTAssertEqual(h2.value(forHTTPHeaderField: "Content-Range"), "bytes 100-199/1000")
        XCTAssertEqual(part, bytes[100..<200])

        req.setValue("bytes=-10", forHTTPHeaderField: "Range")
        let (tail, _) = try await URLSession.shared.data(for: req)
        XCTAssertEqual(tail, bytes[990..<1000])

        let (_, r404) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/t/missing.m4a")!)
        XCTAssertEqual((r404 as? HTTPURLResponse)?.statusCode, 404)
    }

    /// After a restart the speaker may ask for a converted file the server hasn't published yet.
    func testCachedFilesServedByNameOnly() async throws {
        let server = FileServer()
        server.start()
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KlangPlayer", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "test\(Int.random(in: 100000...999999))"
        let file = dir.appendingPathComponent("\(name).m4a")
        try Data("audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        func code(_ path: String) async throws -> Int {
            let (_, r) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(server.port)\(path)")!)
            return (r as? HTTPURLResponse)?.statusCode ?? 0
        }
        let ok = try await code("/t/\(name).m4a")
        XCTAssertEqual(ok, 200)
        let wrongExt = try await code("/t/\(name).txt")
        XCTAssertEqual(wrongExt, 404)
        let traversal = try await code("/t/..%2F..%2FPreferences.m4a")
        XCTAssertEqual(traversal, 404)
        let debugLog = try await code("/t/debug.log")
        XCTAssertEqual(debugLog, 404)
    }
}

/// The local API must answer this Mac's own clients but not web pages open in a browser.
final class LocalAPIAccessTests: XCTestCase {
    private var server: FileServer!

    override func setUp() {
        server = FileServer()
        server.api = { _, _, _ in (200, "application/json", Data("{}".utf8)) }
        server.remoteKey = "secret-key"
        server.start()
    }

    /// Raw request, so Host and browser headers can be set freely. Returns the HTTP status.
    private func status(_ path: String, host: String? = nil, headers: [String: String] = [:]) -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(server.port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { return -1 }
        var req = "POST \(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(server.port)")\r\n"
        for (k, v) in headers { req += "\(k): \(v)\r\n" }
        req += "Content-Length: 0\r\n\r\n"
        _ = req.withCString { send(fd, $0, strlen($0), 0) }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 12 else { return -1 }
        return Int(String(decoding: buf[9..<12], as: UTF8.self)) ?? -1
    }

    func testThisMacIsAllowed() {
        XCTAssertEqual(status("/api/toggle"), 200)
        XCTAssertEqual(status("/api/toggle", host: "localhost:\(server.port)"), 200)
    }

    func testWebPageIsRejected() {
        XCTAssertEqual(status("/api/volume?v=32", headers: ["Origin": "https://evil.example"]), 403)
        XCTAssertEqual(status("/api/next", headers: ["Sec-Fetch-Site": "cross-site"]), 403)
    }

    func testDNSRebindingIsRejected() {
        XCTAssertEqual(status("/api/state", host: "evil.example:\(server.port)"), 403)
    }

    func testRemoteKey() {
        XCTAssertEqual(status("/api/next?k=secret-key", headers: ["Origin": "https://evil.example"]), 200)
        XCTAssertEqual(status("/api/next?k=wrong-key", headers: ["Origin": "https://evil.example"]), 403)
        XCTAssertTrue(constantTimeEqual("abc", "abc"))
        XCTAssertFalse(constantTimeEqual("abc", "abd"))
        XCTAssertFalse(constantTimeEqual("abc", "abcd"))
    }
}


final class LastFMTests: XCTestCase {
    func testSignatureSortsParamsAndSkipsFormat() {
        let p = ["method": "track.love", "api_key": "k", "sk": "sess", "track": "Парашютист", "format": "json"]
        XCTAssertEqual(LastFM.signature(p, secret: "s"), "55c19cd797f7074da35187467414627f")
    }

    func testEncodeEscapesCyrillic() {
        XCTAssertEqual(LastFM.encode("Deadушки & Co"), "Dead%D1%83%D1%88%D0%BA%D0%B8%20%26%20Co")
    }

    func testSummaryToPlainText() {
        let html = "Ashes &amp; dust. <b>Bold</b> <a href=\"https://www.last.fm/music/x\">Read more on Last.fm</a>"
        XCTAssertEqual(LastFM.plainText(html), "Ashes & dust. Bold")
    }
}

final class LyricsTests: XCTestCase {
    func testParseLRC() {
        let l = Lyrics.parseLRC("[ar: X]\n[00:12.50] First line\n[01:02.00][01:30.00] Chorus\n[00:20.00]\nnot a line")
        XCTAssertEqual(l.map(\.time), [12.5, 20, 62, 90])
        XCTAssertEqual(l.map(\.text), ["First line", "", "Chorus", "Chorus"])
    }

    func testCurrentLine() {
        let lyrics = Lyrics(lines: Lyrics.parseLRC("[00:10.00]a\n[00:20.00]b"), plain: nil)
        XCTAssertNil(lyrics.current(at: 5))
        XCTAssertEqual(lyrics.current(at: 10), 0)
        XCTAssertEqual(lyrics.current(at: 25), 1)
    }
}
