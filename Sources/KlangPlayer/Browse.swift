import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case albums, artists, folders
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .albums: "Albums"
        case .artists: "Artists"
        case .folders: "Folders"
        }
    }
}

enum Route: Hashable {
    case album(Album)
    case artist(Artist)
    case folder(FolderEntry)
}

struct ContentView: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var lib = Library.shared
    @State private var tab: Tab = .albums
    @State private var stacks: [Tab: [Route]] = [:]
    @State private var query = ""
    @State private var overlay: Overlay?
    @FocusState private var searchFocused: Bool
    @FocusState private var rootFocused: Bool

    enum Overlay { case settings, queue }

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingView { overlay = overlay == .queue ? nil : .queue }
            Divider()
            Group {
                switch overlay {
                case .settings:
                    SettingsView { overlay = nil; Task { await lib.load() } }
                case .queue:
                    QueueView { overlay = nil }
                case nil:
                    browser
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
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

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                SearchField(text: $query, focused: $searchFocused)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onChange(of: query) { lib.search(query) }

            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                SearchResultsView(query: query) { push($0) }
            } else if let route = stacks[tab]?.last {
                routeView(route)
            } else {
                switch tab {
                case .albums: AlbumsGrid(albums: lib.albums) { push(.album($0)) }
                case .artists: ArtistsList { push(.artist($0)) }
                case .folders: FolderRoot { push(.folder($0)) }
                }
            }
        }
    }

    @ViewBuilder
    private func routeView(_ r: Route) -> some View {
        switch r {
        case .album(let a): AlbumView(album: a, back: pop)
        case .artist(let a): ArtistView(artist: a, back: pop) { push(.album($0)) }
        case .folder(let f): FolderView(folder: f, back: pop) { push(.folder($0)) }
        }
    }

    private func push(_ r: Route) {
        if !query.isEmpty {
            // Opening something from search: show it in the matching tab.
            switch r {
            case .album: tab = .albums
            case .artist: tab = .artists
            case .folder: tab = .folders
            }
            query = ""
        }
        stacks[tab, default: []].append(r)
    }

    private func pop() { _ = stacks[tab]?.popLast() }

    private func seek(_ delta: Double) -> KeyPress.Result {
        guard player.current != nil else { return .ignored }
        player.seek(to: min(max(0, player.position + delta), max(0, player.duration - 1)))
        return .handled
    }

    /// Esc: clear search → close queue/settings → go back.
    private func back() -> KeyPress.Result {
        if !query.isEmpty { query = ""; return .handled }
        if overlay != nil { overlay = nil; return .handled }
        if !(stacks[tab]?.isEmpty ?? true) { pop(); return .handled }
        return .ignored
    }

    /// Invisible buttons that carry ⌘ shortcuts.
    private var hotkeys: some View {
        Group {
            Button("") { overlay = nil; searchFocused = true }.keyboardShortcut("f", modifiers: .command)
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
            Text(player.status ?? lib.error ?? speakerLine)
                .font(.system(size: 10.5))
                .foregroundStyle(player.status != nil || lib.error != nil ? .red : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("Quit")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
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
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: Albums

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
                Cover(url: Emby.shared.imageURL(itemId: album.imageItemId, tag: album.imageTag, size: 260), size: 112)
                    .shadow(color: .black.opacity(hover ? 0.3 : 0.12), radius: hover ? 6 : 3, y: 2)
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

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(title: album.artist, back: back)
            ScrollView {
                VStack(spacing: 0) {
                    CollectionHeader(
                        cover: Emby.shared.imageURL(itemId: album.imageItemId, tag: album.imageTag, size: 300),
                        title: album.Name,
                        subtitle: [album.artist, album.ProductionYear.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                        detail: tracks.isEmpty ? nil : String(localized: "\(tracks.count) tracks") + " · \(totalDuration(tracks)) · \(tracks.first?.sourceLabel ?? "")",
                        tracks: tracks)
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
        .task(id: album.Id) {
            do { tracks = try await lib.tracks(for: album) } catch { self.error = error.localizedDescription }
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
    var placeholder = "music.note"

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Cover(url: cover, size: 104, radius: 8, placeholder: placeholder)
                .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(3)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let detail {
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
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
    let artist: Artist
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Cover(url: Emby.shared.imageURL(itemId: artist.cover?.imageItemId, tag: artist.cover?.imageTag, size: 90),
                  size: 34, radius: 17, placeholder: "music.mic")
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
    let open: (Album) -> Void

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(title: artist.name, back: back)
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
            AlbumsGrid(albums: artist.albums, open: open)
        }
    }

    private func allTracks() async -> [Track] {
        var out: [Track] = []
        for a in artist.albums { out += (try? await lib.tracks(for: a)) ?? [] }
        return out
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
                            cover: Emby.shared.imageURL(itemId: tracks.first?.AlbumId, tag: tracks.first?.AlbumPrimaryImageTag, size: 300),
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
