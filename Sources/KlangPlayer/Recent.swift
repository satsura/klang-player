import SwiftUI

/// "Recent": what to play now — continue, smart mixes, albums listened to lately, new in the library.
struct RecentView: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var lib = Library.shared
    let open: (Route) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if player.current != nil { ContinueCard(open: open).padding(.horizontal, 12).padding(.top, 4) }
                SmartMixBar()
                if !lib.recentPlayedAlbums.isEmpty {
                    SectionTitle("Recently Played")
                    Shelf { ForEach(lib.recentPlayedAlbums) { a in AlbumTile(album: a) { open(.album(a)) } } }
                }
                if !lib.recentAlbums.isEmpty {
                    SectionTitle("New in the Library")
                    Shelf { ForEach(lib.recentAlbums) { a in AlbumTile(album: a) { open(.album(a)) } } }
                }
                let playlists = lib.playlists.filter { ($0.ChildCount ?? 1) > 0 }
                if !playlists.isEmpty {
                    SectionTitle("Playlists")
                    Shelf { ForEach(playlists) { p in PlaylistTile(playlist: p) { open(.playlist(p)) } } }
                }
                HStack(spacing: 8) {
                    LinkButton(title: "Favorites", icon: "heart.fill", tint: .pink) { open(.favorites) }
                    LinkButton(title: "Statistics", icon: "chart.bar.fill", tint: .accentColor) { open(.stats) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .padding(.bottom, 6)
        }
        .task { await lib.loadHome() }
    }
}

/// The current / last played track with one-click continue.
struct ContinueCard: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var lib = Library.shared
    let open: (Route) -> Void

    var body: some View {
        if let t = player.current {
            HStack(spacing: 10) {
                Cover(url: t.artURL(size: 120), size: 48, radius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.state == .playing ? LocalizedStringKey("Now Playing") : LocalizedStringKey("Continue"))
                        .font(.system(size: 9.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                    Text(verbatim: t.Album ?? t.Name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(verbatim: "\(t.artist) · " + String(localized: "track \(player.index + 1) of \(player.queue.count)"))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { player.toggle() } label: {
                    Image(systemName: player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30)).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(player.state == .playing ? Text("Pause") : Text("Play"))
            }
            .padding(10)
            .glass(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { if let a = lib.album(for: t) { open(.album(a)) } }
        }
    }
}

/// Horizontal row of tiles.
struct Shelf<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) { content }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
        }
    }
}

struct LinkButton: View {
    let title: LocalizedStringKey
    let icon: String
    var tint: Color = .accentColor
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .glass(RoundedRectangle(cornerRadius: 10, style: .continuous), interactive: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Favorite albums and tracks.
struct FavoritesView: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var lib = Library.shared
    let back: (() -> Void)?
    var open: (Route) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if let back { NavHeader(title: String(localized: "Favorites"), back: back) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !lib.favoriteTracks.isEmpty {
                        HStack(spacing: 6) {
                            Button { player.play(lib.favoriteTracks) } label: {
                                Label("Play", systemImage: "play.fill").font(.system(size: 11, weight: .semibold))
                            }.buttonStyle(.borderedProminent)
                            Button { player.play(lib.favoriteTracks.shuffled()) } label: {
                                Label("Shuffle", systemImage: "shuffle").font(.system(size: 11))
                            }.buttonStyle(.bordered)
                            Spacer()
                        }
                        .controlSize(.small)
                        .padding(.horizontal, 14).padding(.top, 8)
                    }
                    if !lib.favoriteAlbums.isEmpty {
                        SectionTitle("Albums")
                        Shelf { ForEach(lib.favoriteAlbums) { a in AlbumTile(album: a) { open(.album(a)) } } }
                    }
                    if !lib.favoriteTracks.isEmpty {
                        SectionTitle("Tracks")
                        ForEach(Array(lib.favoriteTracks.enumerated()), id: \.element.id) { i, t in
                            TrackRow(track: t, showArtist: true, showCover: true) { player.play(lib.favoriteTracks, at: i) }
                        }
                    }
                    if lib.favoriteAlbums.isEmpty && lib.favoriteTracks.isEmpty {
                        EmptyState(icon: "heart", text: String(localized: "No favorites yet: tap ♥ on a track or album"))
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .task { await lib.loadHome() }
    }
}

/// All playlists (large window).
struct PlaylistsView: View {
    @ObservedObject var lib = Library.shared
    let open: (Route) -> Void
    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 130), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            if lib.playlists.isEmpty {
                EmptyState(icon: "music.note.list", text: String(localized: "No playlists: use “Add to Playlist” in a track's menu"))
            }
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(lib.playlists) { p in PlaylistTile(playlist: p) { open(.playlist(p)) } }
            }
            .padding(12)
        }
        .task { await lib.loadHome() }
    }
}
