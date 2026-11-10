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
}
