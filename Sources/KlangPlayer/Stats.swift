import SwiftUI

/// Listening statistics from Last.fm: plays, approximate hours, top artists / albums / tracks.
struct StatsView: View {
    @ObservedObject var lib = Library.shared
    let back: (() -> Void)?
    let open: (Route) -> Void

    enum Period: String, CaseIterable, Identifiable {
        case month = "1month", year = "12month", all = "overall"
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self { case .month: "Month"; case .year: "Year"; case .all: "All Time" }
        }
        var since: Date? {
            switch self {
            case .month: Calendar.current.date(byAdding: .month, value: -1, to: Date())
            case .year: Calendar.current.date(byAdding: .year, value: -1, to: Date())
            case .all: nil
            }
        }
    }

    @AppStorage("statsPeriod") private var period: Period = .month
    @State private var plays: Int?
    @State private var artists: [LastFM.Top] = []
    @State private var albums: [LastFM.Top] = []
    @State private var tracks: [LastFM.Top] = []
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            if let back { NavHeader(title: String(localized: "Statistics"), back: back) }
            Picker("", selection: $period) { ForEach(Period.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14).padding(.vertical, 8)
            if !LastFM.isConnected {
                EmptyState(icon: "chart.bar", text: String(localized: "Connect Last.fm in Settings to see your statistics"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            tile(plays.map { $0.formatted() } ?? "…", "plays")
                            // ≈ plays × 4 minutes: Last.fm doesn't store how long each play was.
                            tile(plays.map { "≈ \(($0 * 4 / 60).formatted())" } ?? "…", "hours")
                            tile(artists.isEmpty ? "…" : "\(artists.count)+", "artists")
                        }
                        .padding(.horizontal, 14).padding(.bottom, 6)
                        if !artists.isEmpty {
                            SectionTitle("Top Artists")
                            ForEach(Array(artists.enumerated()), id: \.element.id) { i, a in
                                row(rank: i + 1, title: a.name, subtitle: nil, plays: a.plays, max: artists.first?.plays ?? 1) {
                                    if let la = lib.artists.first(where: { Library.artistKey($0.name) == Library.artistKey(a.name) }) {
                                        open(.artist(la))
                                    } else {
                                        open(.newArtist(a.name))
                                    }
                                }
                            }
                        }
                        if !albums.isEmpty {
                            SectionTitle("Top Albums")
                            Shelf(albums) { a in
                                let local = lib.albums.first { Covers.key($0.Name) == Covers.key(a.name) }
                                DiscoverTile(image: (local.flatMap { lib.coverURL($0, size: 260) } ?? a.image)?.absoluteString,
                                             title: a.name, subtitle: String(localized: "\(a.artist) · \(a.plays) plays")) {
                                    if let local { open(.album(local)) } else { open(.newArtist(a.artist)) }
                                }
                            }
                        }
                        if !tracks.isEmpty {
                            SectionTitle("Top Tracks")
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                                row(rank: i + 1, title: t.name, subtitle: t.artist, plays: t.plays, max: tracks.first?.plays ?? 1) { }
                            }
                        }
                        if loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16) }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
        .task(id: period) { await load() }
    }

    private func load() async {
        guard LastFM.isConnected else { return }
        loading = true
        async let p = LastFM.shared.scrobbles(since: period.since)
        async let ar = LastFM.shared.userTop("artists", period: period.rawValue, limit: 10)
        async let al = LastFM.shared.userTop("albums", period: period.rawValue, limit: 10)
        async let tr = LastFM.shared.userTop("tracks", period: period.rawValue, limit: 10)
        plays = await p
        artists = await ar
        albums = await al
        tracks = await tr
        loading = false
    }

    private func tile(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value).font(.system(size: 18, weight: .bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .glass(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(rank: Int, title: String, subtitle: String?, plays: Int, max: Int, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Text("\(rank)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.tertiary).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).font(.system(size: 12)).lineLimit(1)
                    if let subtitle { Text(verbatim: subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                    GeometryReader { g in
                        Capsule().fill(Color.accentColor.opacity(0.5))
                            .frame(width: g.size.width * CGFloat(plays) / CGFloat(Swift.max(1, max)))
                    }
                    .frame(height: 3)
                }
                Text("\(plays)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
