import SwiftUI

struct ContentView: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var lib = Library.shared
    @StateObject private var nav = BrowserState()
    @State private var overlay: Overlay?
    @FocusState private var searchFocused: Bool
    @FocusState private var rootFocused: Bool

    enum Overlay: Equatable { case settings, queue, lyrics, cover(Album) }

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingView(showQueue: { overlay = overlay == .queue ? nil : .queue },
                           showLyrics: { overlay = overlay == .lyrics ? nil : .lyrics },
                           pickCover: { overlay = .cover($0) })
            Group {
                switch overlay {
                case .settings:
                    SettingsView { overlay = nil; Task { await lib.load() } }
                case .queue:
                    QueueView { overlay = nil }
                case .lyrics:
                    LyricsView { overlay = nil }
                case .cover(let album):
                    ScrollView {
                        CoverPicker(album: album, artist: album.parts == nil ? album.artist : "") { _ in overlay = nil }
                    }
                case nil:
                    BrowserView(state: nav, searchFocused: $searchFocused)
                }
            }
            .frame(maxHeight: .infinity)
            // The footer floats over the content, which scrolls under it.
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        }
        .background { AmbientArt(url: player.current?.artURL(size: 300)) }
        .frame(width: 400, height: 680)
        .focusable()
        .focusEffectDisabled()
        .focused($rootFocused)
        .onKeyPress(.space) { player.toggle(); return .handled }
        .onKeyPress(.leftArrow) { seek(-10) }
        .onKeyPress(.rightArrow) { seek(10) }
        .onKeyPress(.escape) { back() }
        .background { hotkeys }
        .onAppear {
            if !Config.isConfigured { overlay = .settings }
            rootFocused = true
        }
    }

    private func seek(_ delta: Double) -> KeyPress.Result {
        guard player.current != nil else { return .ignored }
        player.seek(to: min(max(0, player.position + delta), max(0, player.duration - 1)))
        return .handled
    }

    /// Esc: close queue/settings → clear search → go back.
    private func back() -> KeyPress.Result {
        if overlay != nil { overlay = nil; return .handled }
        return nav.back() ? .handled : .ignored
    }

    /// Invisible buttons that carry ⌘ shortcuts.
    private var hotkeys: some View {
        Group {
            Button("") { overlay = nil; nav.searching = true; searchFocused = true }.keyboardShortcut("f", modifiers: .command)
            Button("") { player.setVolume(player.volume + 1) }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("") { player.setVolume(player.volume - 1) }.keyboardShortcut(.downArrow, modifiers: .command)
            Button("") { _ = back() }.keyboardShortcut("[", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { overlay = overlay == .settings ? nil : .settings } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
            if lib.loading {
                ProgressView().controlSize(.mini)
            }
            if let err = player.status ?? lib.error {
                Text(err)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                speakerMenu
            }
            Spacer()
            Button { StatusBar.shared.openWindow() } label: { Image(systemName: "macwindow") }
                .buttonStyle(.borderless)
                .help("Open in Window")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("Quit")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glass(Capsule())
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    /// Speaker name with a menu to switch to another speaker.
    private var speakerMenu: some View {
        Menu {
            ForEach(Config.knownSpeakers) { sp in
                Button {
                    player.useSpeaker(sp)
                } label: {
                    let line = "\(sp.name) · \(sp.formatLabel)"
                    if sp.id == Config.speaker?.id { Label(line, systemImage: "checkmark") } else { Text(verbatim: line) }
                }
            }
            if !Config.knownSpeakers.isEmpty { Divider() }
            if Speaker.shared.canPower {
                Button("Turn Off Speaker") { player.turnOffSpeaker() }
            }
            Button("Find Speakers…") {
                overlay = .settings
                Task { await Player.relocateSpeaker() }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "hifispeaker").font(.system(size: 10))
                Text(verbatim: speakerLine).font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var speakerLine: String {
        guard Config.isConfigured else { return String(localized: "Not set up") }
        let name = Config.speakerName.isEmpty ? Config.speakerIP : Config.speakerName
        return "\(name) · " + String(localized: "\(lib.albums.count) albums")
    }
}

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .focused(focused)
                .onKeyPress(.escape) {
                    if text.isEmpty { focused.wrappedValue = false } else { text = "" }
                    return .handled
                }
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glass(Capsule())
    }
}

// MARK: Albums

/// Albums tab: the grid with a sort order (by name or by popularity on Last.fm).
struct AlbumsTab: View {
    @ObservedObject var lib = Library.shared
    @AppStorage("albumSort") private var sort = "name"
    let open: (Album) -> Void

    private var sorted: [Album] {
        guard sort == "popular" else { return lib.albums }
        // Popular first; albums without data keep their order at the end.
        return lib.albums.enumerated().sorted { x, y in
            let a = lib.listeners[x.element.Id] ?? -1, b = lib.listeners[y.element.Id] ?? -1
            return a != b ? a > b : x.offset < y.offset
        }.map(\.element)
    }

    var body: some View {
        VStack(spacing: 0) {
            if LastFM.hasKey {
                HStack {
                    Spacer()
                    Picker("Sort", selection: $sort) {
                        Text("By Name").tag("name")
                        Text("By Popularity").tag("popular")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
            }
            AlbumsGrid(albums: sorted, open: open)
        }
        .task(id: sort) { if sort == "popular" { await lib.loadPopularity() } }
    }
}

struct AlbumsGrid: View {
    @ObservedObject var lib = Library.shared
    let albums: [Album]
    let open: (Album) -> Void

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 130), spacing: 12, alignment: .top)]

    var body: some View {
        if lib.loading && albums.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if albums.isEmpty {
            EmptyState(icon: "square.stack", text: lib.error ?? String(localized: "No albums"),
                       action: ("Refresh", { Task { await lib.load() } }))
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(albums) { a in AlbumTile(album: a) { open(a) } }
                }
                .padding(12)
            }
        }
    }
}

struct AlbumTile: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var lib = Library.shared
    let album: Album
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                Cover(url: lib.coverURL(album, size: 260), size: 112)
                    .shadow(color: .black.opacity(hover ? 0.3 : 0.12), radius: hover ? 6 : 3, y: 2)
                    .task(id: album.Id) { await lib.loadTrackCover(album) }
                if hover {
                    Button {
                        Task { if let t = try? await lib.tracks(for: album) { player.play(t) } }
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(radius: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            }
            Text(album.Name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Text(album.artist)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 112)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Play") { Task { if let t = try? await lib.tracks(for: album) { player.play(t) } } }
            Button("Shuffle") { Task { if let t = try? await lib.tracks(for: album) { player.play(t.shuffled()) } } }
            Button("Play Next") { Task { if let t = try? await lib.tracks(for: album) { player.playNext(t) } } }
            Button("Add to Queue") { Task { if let t = try? await lib.tracks(for: album) { player.enqueue(t) } } }
            AddToPlaylistMenu { (try? await lib.tracks(for: album)) ?? [] }
            if album.parts == nil {
                Divider()
                let fav = lib.isFavorite(album.Id, server: album.UserData?.IsFavorite ?? false)
                Button(fav ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Add to Favorites")) {
                    lib.toggleFavorite(album.Id, current: fav)
                }
            }
        }
    }
}

struct AlbumView: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var lib = Library.shared
    let album: Album
    let back: () -> Void
    @State private var tracks: [Track] = []
    @State private var error: String?
    @State private var pickingCover = false
    @ObservedObject private var lyricsStore = LyricsStore.shared

    private var lyricsCount: (found: Int, of: Int)? {
        let checked = tracks.filter { lyricsStore.known[$0.Id] != nil }
        guard !checked.isEmpty else { return nil }
        return (checked.filter { lyricsStore.known[$0.Id] == true }.count, tracks.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(title: album.artist, back: back)
            if pickingCover {
                ScrollView {
                    CoverPicker(album: album, artist: album.parts == nil ? album.artist : "") { _ in pickingCover = false }
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        CollectionHeader(
                            cover: lib.coverURL(album, size: 300) ?? tracks.first(where: { $0.ImageTags?["Primary"] != nil })?.artURL(size: 300),
                            title: album.Name,
                            subtitle: [album.artist, album.ProductionYear.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                            detail: tracks.isEmpty ? nil : String(localized: "\(tracks.count) tracks") + " · \(totalDuration(tracks)) · \(tracks.first?.sourceLabel ?? "")",
                            tracks: tracks,
                            popularity: lib.listeners[album.Id],
                            favorite: album.parts != nil ? nil : (
                                lib.isFavorite(album.Id, server: album.UserData?.IsFavorite ?? false),
                                { lib.toggleFavorite(album.Id, current: lib.isFavorite(album.Id, server: album.UserData?.IsFavorite ?? false)) }
                            ),
                            badges: CoverBadges(hiRes: tracks.contains(where: \.isHiRes), lyrics: lyricsCount,
                                                favorite: lib.isFavorite(album.Id, server: album.UserData?.IsFavorite ?? false)),
                            refreshCover: { pickingCover = true })
                        if album.parts == nil {
                            AboutSection(subject: .album(artist: album.artist, name: album.Name))
                        }
                        if let error { Text(error).foregroundStyle(.secondary).padding() }
                        LazyVStack(spacing: 0) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                                TrackRow(track: t, number: t.IndexNumber) { player.play(tracks, at: i) }
                            }
                        }
                        .padding(.bottom, 10)
                    }
                }
            }
        }
        .task(id: album.Id) {
            do { tracks = try await lib.tracks(for: album) } catch { self.error = error.localizedDescription }
            if album.parts == nil {
                await lib.loadPopularTracks(album.artist)
                if lib.listeners[album.Id] == nil,
                   let n = await LastFM.shared.albumListeners(artist: album.artist, album: album.Name) {
                    lib.setListeners(n, for: album.Id)
                }
            }
            await LyricsStore.shared.check(tracks)
        }
    }
}

/// Cover + title + Play / Shuffle buttons for an album or folder.
struct CollectionHeader: View {
    @ObservedObject var player = Player.shared
    let cover: URL?
    let title: String
    let subtitle: String
    let detail: String?
    let tracks: [Track]
    /// Listeners on Last.fm.
    var popularity: Int? = nil
    var favorite: (isOn: Bool, toggle: () -> Void)? = nil
    var placeholder = "music.note"
    var badges: CoverBadges? = nil
    /// Shows a "find another cover" button on the cover on hover.
    var refreshCover: (() -> Void)? = nil
    @State private var hoverCover = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Cover(url: cover, size: 104, radius: 8, placeholder: placeholder)
                .overlay(alignment: .bottomLeading) { badges }
                .overlay(alignment: .topTrailing) {
                    if let refreshCover, hoverCover {
                        GlassIconButton(icon: "arrow.triangle.2.circlepath", label: "Find another cover",
                                        size: 24, symbolSize: 10, overImage: true, action: refreshCover)
                            .padding(4)
                    }
                }
                .onHover { hoverCover = $0 }
                .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(3)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let detail {
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
                if let popularity, popularity > 0 {
                    Label(String(localized: "\(popularity.formatted(.number.notation(.compactName))) listeners on Last.fm"),
                          systemImage: "person.2.fill")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    Button { player.play(tracks) } label: {
                        Label("Play", systemImage: "play.fill").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    Button { player.play(tracks.shuffled()) } label: {
                        Label("Shuffle", systemImage: "shuffle").font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    if let favorite {
                        Button(action: favorite.toggle) {
                            Image(systemName: favorite.isOn ? "heart.fill" : "heart")
                                .foregroundStyle(favorite.isOn ? Color.pink : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(favorite.isOn ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Add to Favorites"))
                    }
                }
                .controlSize(.small)
                .disabled(tracks.isEmpty)
            }
            .frame(minHeight: 104, alignment: .topLeading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}

// MARK: Artists

struct ArtistsList: View {
    @ObservedObject var lib = Library.shared
    let open: (Artist) -> Void

    var body: some View {
        if lib.artists.isEmpty {
            EmptyState(icon: "music.mic", text: lib.loading ? String(localized: "Loading…") : String(localized: "No artists"))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(lib.artists) { a in ArtistRow(artist: a) { open(a) } }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

struct ArtistRow: View {
    @ObservedObject var lib = Library.shared
    let artist: Artist
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Cover(url: artist.cover.flatMap { lib.coverURL($0, size: 90) },
                  size: 34, radius: 17, placeholder: "music.mic")
                .task(id: artist.id) { if let c = artist.cover { await lib.loadTrackCover(c) } }
            VStack(alignment: .leading, spacing: 1) {
                Text(artist.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(artist.albums.count) albums")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .hoverable()
        .onTapGesture(perform: open)
    }
}

struct ArtistView: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var lib = Library.shared
    let artist: Artist
    let back: () -> Void
    let open: (Route) -> Void
    @State private var popular: [Track] = []
    @State private var similar: [(name: String, local: Artist?)] = []
    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 130), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(title: artist.name, back: back)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Button { Task { player.play(await allTracks()) } } label: {
                            Label("Play All", systemImage: "play.fill").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        Button { Task { player.play(await allTracks().shuffled()) } } label: {
                            Label("Shuffle", systemImage: "shuffle").font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    AboutSection(subject: .artist(artist.name))
                    if !popular.isEmpty {
                        SectionTitle("Popular")
                        ForEach(Array(popular.prefix(5).enumerated()), id: \.element.id) { i, t in
                            TrackRow(track: t, showArtist: false, showCover: true) { player.play(popular, at: i) }
                        }
                    }
                    SectionTitle("Albums")
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(artist.albums) { a in AlbumTile(album: a) { open(.album(a)) } }
                    }
                    .padding(.horizontal, 12)
                    if !similar.isEmpty {
                        SectionTitle("Similar Artists")
                        FlowChips(items: similar.map(\.name), marked: Set(similar.filter { $0.local != nil }.map(\.name))) { name in
                            if let a = similar.first(where: { $0.name == name })?.local { open(.artist(a)) } else { open(.newArtist(name)) }
                        }
                        .padding(.horizontal, 14)
                        Text("Highlighted: in your library").font(.system(size: 9.5)).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.top, 4)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .task(id: artist.name) {
            let names = await LastFM.shared.topTrackNames(artist.name)
            if !names.isEmpty {
                let all = await allTracks()
                var seen = Set<String>()
                popular = names.compactMap { n in all.first { LastFM.normalize($0.Name) == n } }.filter { seen.insert($0.Id).inserted }
            }
            let byKey = Dictionary(lib.artists.map { (Library.artistKey($0.name), $0) }, uniquingKeysWith: { a, _ in a })
            let list = await LastFM.shared.similarArtists(artist.name, limit: 20).map { ($0, byKey[Library.artistKey($0)]) }
            similar = list.filter { $0.1 != nil } + list.filter { $0.1 == nil }
        }
    }

    private func allTracks() async -> [Track] {
        var out: [Track] = []
        for a in artist.albums { out += (try? await lib.tracks(for: a)) ?? [] }
        return out
    }
}

/// Wrapping row of tappable name chips; `marked` ones are highlighted.
struct FlowChips: View {
    let items: [String]
    let marked: Set<String>
    let tap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { name in
                Button { tap(name) } label: {
                    Text(verbatim: name).font(.system(size: 11))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .foregroundStyle(marked.contains(name) ? Color.accentColor : .primary)
                        .background(Capsule().fill(marked.contains(name) ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Lays children out left to right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 300, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, p) in arrange(bounds.width, subviews).points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        var pts: [CGPoint] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += line + spacing; line = 0 }
            pts.append(CGPoint(x: x, y: y))
            x += sz.width + spacing
            line = max(line, sz.height)
            maxX = max(maxX, x)
        }
        return (CGSize(width: maxX, height: y + line), pts)
    }
}

// MARK: Folders

struct FolderRoot: View {
    @ObservedObject var lib = Library.shared
    let open: (FolderEntry) -> Void

    var body: some View {
        if lib.roots.count == 1, let root = lib.roots.first {
            FolderView(folder: root, back: nil, open: open)
        } else if lib.roots.isEmpty {
            EmptyState(icon: "folder", text: lib.loading ? String(localized: "Loading…") : String(localized: "No music libraries"))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(lib.roots) { f in FolderRow(folder: f) { open(f) } }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

struct FolderView: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var lib = Library.shared
    let folder: FolderEntry
    let back: (() -> Void)?
    let open: (FolderEntry) -> Void

    @State private var folders: [FolderEntry] = []
    @State private var tracks: [Track] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let back { NavHeader(title: folder.Name, back: back) }
            ScrollView {
                VStack(spacing: 0) {
                    if !tracks.isEmpty {
                        CollectionHeader(
                            cover: Emby.shared.imageURL(itemId: folder.Id, tag: folder.imageTag, size: 300) ?? tracks.first?.artURL(size: 300),
                            title: folder.Name,
                            subtitle: tracks.first?.AlbumArtist ?? "",
                            detail: String(localized: "\(tracks.count) files") + " · \(totalDuration(tracks)) · \(tracks.first?.sourceLabel ?? "")",
                            tracks: tracks,
                            placeholder: "folder")
                    } else if !folders.isEmpty {
                        HStack(spacing: 6) {
                            Button { Task { await playAll(shuffle: false) } } label: {
                                Label("Play Folder", systemImage: "play.fill").font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            Button { Task { await playAll(shuffle: true) } } label: {
                                Label("Shuffle", systemImage: "shuffle").font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            Text("\(folders.count) folders").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                        .controlSize(.small)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                    }

                    LazyVStack(spacing: 0) {
                        ForEach(folders) { f in FolderRow(folder: f) { open(f) } }
                        if !folders.isEmpty && !tracks.isEmpty { Divider().padding(.vertical, 4) }
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                            TrackRow(track: t, number: t.IndexNumber) { player.play(tracks, at: i) }
                        }
                    }
                    .padding(.bottom, 10)

                    if loaded && folders.isEmpty && tracks.isEmpty {
                        EmptyState(icon: "folder", text: error ?? String(localized: "Folder is empty"))
                    } else if !loaded {
                        ProgressView().padding(30)
                    }
                }
                .padding(.top, back == nil ? 4 : 0)
            }
        }
        .task(id: folder.Id) {
            do {
                let c = try await lib.children(of: folder.Id)
                folders = c.folders
                tracks = c.tracks
            } catch {
                self.error = error.localizedDescription
            }
            loaded = true
        }
    }

    private func playAll(shuffle: Bool) async {
        guard let t = try? await Emby.shared.allTracks(under: folder.Id), !t.isEmpty else { return }
        player.play(shuffle ? t.shuffled() : t)
    }
}

struct FolderRow: View {
    @ObservedObject var player = Player.shared
    let folder: FolderEntry
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            if let tag = folder.imageTag {
                Cover(url: Emby.shared.imageURL(itemId: folder.Id, tag: tag, size: 80), size: 30)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor.opacity(0.75))
                    .frame(width: 30, height: 30)
            }
            Text(folder.Name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            if hover {
                Button { Task { await play(shuffle: false) } } label: {
                    Image(systemName: "play.circle.fill").font(.system(size: 16))
                }
                .buttonStyle(.borderless)
                .help("Play Folder")
            } else if let n = folder.ChildCount {
                Text("\(n)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .hoverable()
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Play Folder") { Task { await play(shuffle: false) } }
            Button("Shuffle") { Task { await play(shuffle: true) } }
            Button("Add to Queue") {
                Task { if let t = try? await Emby.shared.allTracks(under: folder.Id) { player.enqueue(t) } }
            }
            AddToPlaylistMenu { (try? await Emby.shared.allTracks(under: folder.Id)) ?? [] }
        }
    }

    private func play(shuffle: Bool) async {
        guard let t = try? await Emby.shared.allTracks(under: folder.Id), !t.isEmpty else { return }
        player.play(shuffle ? t.shuffled() : t)
    }
}

// MARK: Search

struct SearchResultsView: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var lib = Library.shared
    let query: String
    let open: (Route) -> Void

    var body: some View {
        let albums = lib.filteredAlbums(query)
        let artists = lib.filteredArtists(query)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !artists.isEmpty {
                    SectionTitle("Artists")
                    ForEach(artists.prefix(5)) { a in ArtistRow(artist: a) { open(.artist(a)) } }
                }
                if !albums.isEmpty {
                    SectionTitle("Albums")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(albums) { a in AlbumTile(album: a) { open(.album(a)) } }
                        }
                        .padding(.horizontal, 14)
                    }
                }
                if !lib.searchResults.isEmpty {
                    SectionTitle("Tracks")
                    ForEach(Array(lib.searchResults.enumerated()), id: \.element.id) { i, t in
                        TrackRow(track: t, showArtist: true, showCover: true) { player.play(lib.searchResults, at: i) }
                    }
                }
                if albums.isEmpty && artists.isEmpty && lib.searchResults.isEmpty {
                    EmptyState(icon: "magnifyingglass", text: String(localized: "Nothing found"))
                }
            }
            .padding(.bottom, 10)
        }
    }
}

// MARK: Home


struct PlaylistTile: View {
    let playlist: FolderEntry
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Cover(url: Emby.shared.imageURL(itemId: playlist.Id, tag: playlist.imageTag, size: 260), size: 112,
                  placeholder: "music.note.list")
                .shadow(color: .black.opacity(hover ? 0.3 : 0.12), radius: hover ? 6 : 3, y: 2)
            Text(playlist.Name).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Text("\(playlist.ChildCount ?? 0) tracks").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(width: 112)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
    }
}

struct PlaylistView: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var lib = Library.shared
    let playlist: FolderEntry
    let back: () -> Void
    @State private var tracks: [Track] = []
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(title: String(localized: "Playlists"), back: back)
            ScrollView {
                VStack(spacing: 0) {
                    CollectionHeader(
                        cover: Emby.shared.imageURL(itemId: playlist.Id, tag: playlist.imageTag, size: 300),
                        title: playlist.Name, subtitle: "",
                        detail: tracks.isEmpty ? nil : String(localized: "\(tracks.count) tracks") + " · \(totalDuration(tracks))",
                        tracks: tracks, placeholder: "music.note.list")
                    if let error { Text(error).foregroundStyle(.secondary).padding() }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                            TrackRow(track: t, number: i + 1, showArtist: true) { player.play(tracks, at: i) }
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
        .task(id: playlist.Id) {
            do { tracks = try await lib.playlistTracks(playlist.Id) } catch { self.error = error.localizedDescription }
        }
    }
}
