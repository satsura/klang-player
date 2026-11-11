import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case recent, discover, albums, artists, folders
    // Only in the large window's sidebar:
    case playlists, favorites, stats

    var id: Self { self }
    static let popover: [Tab] = [.recent, .discover, .albums, .artists, .folders]

    var title: LocalizedStringKey {
        switch self {
        case .recent: "Recent"
        case .discover: "Discover"
        case .albums: "Albums"
        case .artists: "Artists"
        case .folders: "Folders"
        case .playlists: "Playlists"
        case .favorites: "Favorites"
        case .stats: "Statistics"
        }
    }

    var icon: String {
        switch self {
        case .recent: "clock"
        case .discover: "sparkles"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .folders: "folder"
        case .playlists: "music.note.list"
        case .favorites: "heart"
        case .stats: "chart.bar"
        }
    }
}

enum Route: Hashable {
    case album(Album)
    case artist(Artist)
    case folder(FolderEntry)
    case playlist(FolderEntry)
    case favorites
    case stats
    /// An artist that isn't in the library (from Discover or "similar artists").
    case newArtist(String)
}

/// Tab, back stacks and search of one browser (the popover and the large window each have one).
@MainActor
final class BrowserState: ObservableObject {
    @Published var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .recent {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "tab") }
    }
    @Published var stacks: [Tab: [Route]] = [:]
    @Published var query = ""
    @Published var searching = false

    func push(_ r: Route) {
        if !query.isEmpty {
            // Opening something from search: show it in the matching tab.
            switch r {
            case .album: tab = .albums
            case .artist: tab = .artists
            case .folder: tab = .folders
            default: break
            }
            query = ""
            searching = false
        }
        stacks[tab, default: []].append(r)
    }

    func pop() { _ = stacks[tab]?.popLast() }

    /// Esc: clear search → go back. Returns false if there was nothing to do.
    func back() -> Bool {
        if searching || !query.isEmpty { query = ""; searching = false; return true }
        if !(stacks[tab]?.isEmpty ?? true) { pop(); return true }
        return false
    }

    /// Shows a tab from its start (a click on the current tab returns to its root).
    func select(_ t: Tab) {
        if t == tab { stacks[t] = [] }
        tab = t
    }
}

/// Tabs (in the popover), search and the current tab's content with its back stack.
struct BrowserView: View {
    @ObservedObject var state: BrowserState
    @ObservedObject var lib = Library.shared
    var compact = true
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 0) {
            if compact {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { state.tab }, set: { state.select($0) })) {
                        ForEach(Tab.popover) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Button {
                        state.searching.toggle()
                        if state.searching { searchFocused.wrappedValue = true } else { state.query = "" }
                    } label: {
                        Image(systemName: state.searching ? "xmark.circle.fill" : "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Search (⌘F)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            if !compact || state.searching || !state.query.isEmpty {
                SearchField(text: $state.query, focused: searchFocused)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .padding(.top, compact ? 0 : 10)
            }
            content
        }
        .onChange(of: state.query) { lib.search(state.query) }
    }

    @ViewBuilder
    private var content: some View {
        if !state.query.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchResultsView(query: state.query) { state.push($0) }
        } else if let route = state.stacks[state.tab]?.last {
            routeView(route)
        } else {
            switch state.tab {
            case .recent: RecentView { state.push($0) }
            case .discover: DiscoverView { state.push($0) }
            case .albums: AlbumsTab { state.push(.album($0)) }
            case .artists: ArtistsList { state.push(.artist($0)) }
            case .folders: FolderRoot { state.push(.folder($0)) }
            case .playlists: PlaylistsView { state.push($0) }
            case .favorites: FavoritesView(back: nil) { state.push($0) }
            case .stats: StatsView(back: nil) { state.push($0) }
            }
        }
    }

    @ViewBuilder
    private func routeView(_ r: Route) -> some View {
        switch r {
        case .album(let a): AlbumView(album: a, back: state.pop)
        case .artist(let a): ArtistView(artist: a, back: state.pop) { state.push($0) }
        case .folder(let f): FolderView(folder: f, back: state.pop) { state.push(.folder($0)) }
        case .playlist(let p): PlaylistView(playlist: p, back: state.pop)
        case .favorites: FavoritesView(back: state.pop) { state.push($0) }
        case .stats: StatsView(back: state.pop) { state.push($0) }
        case .newArtist(let name): NewArtistView(name: name, back: state.pop)
        }
    }
}
