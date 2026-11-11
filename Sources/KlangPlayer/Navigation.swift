import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case recent, discover, albums, artists, folders
    // Only in the large window's sidebar:
    case playlists, favorites, stats

    var id: Self { self }
    static let popover: [Tab] = [.recent, .discover, .albums, .artists, .folders]

    var name: String {
        switch self {
        case .recent: String(localized: "Recent")
        case .discover: String(localized: "Discover")
        case .albums: String(localized: "Albums")
        case .artists: String(localized: "Artists")
        case .folders: String(localized: "Folders")
        case .playlists: String(localized: "Playlists")
        case .favorites: String(localized: "Favorites")
        case .stats: String(localized: "Statistics")
        }
    }

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

    /// Filled variant for the selected tab.
    var selectedIcon: String {
        switch self {
        case .recent: "clock.fill"
        case .albums: "square.stack.fill"
        case .folders: "folder.fill"
        case .playlists: "music.note.list"
        case .favorites: "heart.fill"
        case .stats: "chart.bar.fill"
        default: icon
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

    var title: String {
        switch self {
        case .album(let a): a.Name
        case .artist(let a): a.name
        case .folder(let f), .playlist(let f): f.Name
        case .favorites: String(localized: "Favorites")
        case .stats: String(localized: "Statistics")
        case .newArtist(let n): n
        }
    }
}

/// Tab, back stacks and search of one browser (the popover and the large window each have one).
@MainActor
final class BrowserState: ObservableObject {
    @Published var tab: Tab {
        didSet { if !fixed { UserDefaults.standard.set(tab.rawValue, forKey: "tab") } }
    }
    /// The popover stays on one page (Recent); the window has all tabs and remembers the last one.
    private let fixed: Bool

    init(fixed tab: Tab? = nil) {
        self.fixed = tab != nil
        self.tab = tab ?? Tab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .recent
    }
    @Published var stacks: [Tab: [Route]] = [:]
    /// Where "forward" goes after going back (per tab, like a browser).
    @Published var forward: [Tab: [Route]] = [:]
    @Published var query = ""
    @Published var searching = false

    func push(_ r: Route) {
        if !query.isEmpty {
            // Opening something from search: show it in the matching tab (the window).
            if !fixed { switch r {
            case .album: tab = .albums
            case .artist: tab = .artists
            case .folder: tab = .folders
            default: break
            } }
            query = ""
            searching = false
        }
        stacks[tab, default: []].append(r)
        forward[tab] = []
    }

    func pop() {
        guard let r = stacks[tab]?.popLast() else { return }
        forward[tab, default: []].append(r)
    }

    var canGoBack: Bool { !(stacks[tab]?.isEmpty ?? true) }
    var canGoForward: Bool { !(forward[tab]?.isEmpty ?? true) }

    func goForward() {
        guard let r = forward[tab]?.popLast() else { return }
        stacks[tab, default: []].append(r)
    }

    /// The window title: the open page, else the tab.
    var title: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Search") }
        return stacks[tab]?.last?.title ?? tab.name
    }

    /// Esc: clear search → go back. Returns false if there was nothing to do.
    func back() -> Bool {
        if searching || !query.isEmpty { query = ""; searching = false; return true }
        if !(stacks[tab]?.isEmpty ?? true) { pop(); return true }
        return false
    }

    /// Opens a tab at its start, from outside (the popover's library links).
    func show(_ t: Tab) {
        query = ""
        stacks[t] = []
        forward[t] = []
        tab = t
    }

    /// Shows a tab from its start (a click on the current tab returns to its root).
    func select(_ t: Tab) {
        if t == tab { stacks[t] = []; forward[t] = [] }
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
        Group {
            if compact {
                // The popover: the bar floats in glass and lists scroll under it.
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) { header }
            } else {
                // The window: search, title and ‹ › are in its toolbar.
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.wideBrowser, !compact)
        .onChange(of: state.query) { lib.search(state.query) }
    }

    private var header: some View {
        // The popover: search and the way to the full library (the window).
        GlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                SearchField(text: $state.query, focused: searchFocused)
                GlassIconButton(icon: "books.vertical", label: "Open Library", size: 30, symbolSize: 12) {
                    StatusBar.shared.openWindow()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 8)
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
