import Foundation

/// "Keep playing similar music": tracks from the library by artists similar to the seed
/// (Last.fm), topped up with Emby's Instant Mix.
@MainActor
enum Radio {
    static func similar(to seed: Track, excluding: Set<String>, count: Int = 12) async -> [Track] {
        var out: [Track] = []
        var seen = excluding
        func add(_ t: Track) {
            guard out.count < count, seen.insert(t.Id).inserted else { return }
            out.append(t)
        }
        let lib = Library.shared
        let byKey = Dictionary(lib.artists.map { (Library.artistKey($0.name), $0) }, uniquingKeysWith: { a, _ in a })

        // Similar artists that are in the library (plus a little of the seed artist), one or two tracks each.
        let similar = await LastFM.shared.similarArtists(seed.artist)
        var artists = similar.compactMap { byKey[Library.artistKey($0)] }.prefix(8).shuffled()
        if let own = byKey[Library.artistKey(seed.artist)] { artists.append(own) }
        for a in artists where out.count < count {
            guard let album = a.albums.randomElement(),
                  let tracks = try? await lib.tracks(for: album), !tracks.isEmpty else { continue }
            for t in tracks.shuffled().prefix(a.name == seed.artist ? 1 : 2) { add(t) }
        }
        // Not enough (no Last.fm, or few similar artists here): Emby's Instant Mix.
        if out.count < count, let mix = try? await Emby.shared.instantMix(seed.Id) {
            for t in mix.shuffled() { add(t) }
        }
        return out.shuffled()
    }
}
