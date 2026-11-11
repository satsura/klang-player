import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Albums / tracks dragged inside the app (declared in Info.plist).
    static let klangItems = UTType(exportedAs: "io.github.satsura.klangplayer.items")
}

/// What's being dragged: albums (their tracks load on drop) or tracks.
struct DragItems: Codable, Transferable {
    var albumIds: [String] = []
    var tracks: [Track] = []

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .klangItems)
    }

    /// All tracks of the dropped items, in order.
    @MainActor
    static func tracks(_ items: [DragItems]) async -> [Track] {
        let lib = Library.shared
        var out: [Track] = []
        for item in items {
            for id in item.albumIds {
                if let a = lib.albums.first(where: { $0.Id == id }), let t = try? await lib.tracks(for: a) {
                    out += t
                } else if let t = try? await Emby.shared.tracks(album: id) {
                    out += t
                }
            }
            out += item.tracks
        }
        return out
    }
}

extension View {
    /// `.draggable` only when `on` (queue rows reorder instead).
    @ViewBuilder
    func draggable(if on: Bool, _ items: @autoclosure @escaping () -> DragItems) -> some View {
        if on { draggable(items()) } else { self }
    }
}
