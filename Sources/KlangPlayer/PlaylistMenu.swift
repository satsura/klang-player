import SwiftUI

/// "Add to Playlist" submenu: existing playlists and "New Playlist…".
struct AddToPlaylistMenu: View {
    @ObservedObject var lib = Library.shared
    /// Tracks to add (an album loads its tracks first).
    let tracks: () async -> [Track]

    var body: some View {
        Menu("Add to Playlist") {
            Button("New Playlist…") { Task { await lib.addToPlaylist(nil, tracks: await tracks()) } }
            if !lib.playlists.isEmpty { Divider() }
            ForEach(lib.playlists) { p in
                Button(p.Name) { Task { await lib.addToPlaylist(p, tracks: await tracks()) } }
            }
        }
    }
}
