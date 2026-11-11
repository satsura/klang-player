import AppKit
import SwiftUI

/// The large, resizable window: sidebar, library, and now playing with queue / lyrics.
@MainActor
final class LibraryWindow: NSObject, NSWindowDelegate {
    static let shared = LibraryWindow()
    private var window: NSWindow?

    func show(activate: Bool = true) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 740),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Klang Player"
            w.titlebarAppearsTransparent = true
            w.contentMinSize = NSSize(width: 1000, height: 560)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentViewController = NSHostingController(rootView: LibraryWindowView())
            if !w.setFrameUsingName("KlangLibraryWindow") { w.center() }
            w.setFrameAutosaveName("KlangLibraryWindow")
            window = w
        }
        guard activate else { window?.orderFrontRegardless(); return }   // debug screenshots
        // While the window is open the app shows in the Dock and ⌘Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct LibraryWindowView: View {
    @ObservedObject private var player = Player.shared
    @StateObject private var nav = BrowserState()
    @FocusState private var searchFocused: Bool
    @State private var pane: Pane = .queue
    @State private var coverAlbum: Album?

    enum Pane: String, CaseIterable, Identifiable {
        case queue, lyrics
        var id: Self { self }
        var title: LocalizedStringKey { self == .queue ? "Queue" : "Lyrics" }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(nav.tab) }, set: { if let t = $0 { nav.select(t) } })) {
                Section("Library") {
                    ForEach(Tab.popover) { t in Label(t.title, systemImage: t.icon).tag(t) }
                }
                Section {
                    ForEach([Tab.playlists, .favorites, .stats]) { t in Label(t.title, systemImage: t.icon).tag(t) }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } label: { Image(systemName: "gearshape") }
                    .help("Settings")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
        } content: {
            BrowserView(state: nav, compact: false, searchFocused: $searchFocused)
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
        } detail: {
            VStack(spacing: 0) {
                NowPlayingView(showQueue: { pane = .queue }, showLyrics: { pane = .lyrics }, pickCover: { coverAlbum = $0 })
                Picker("", selection: $pane) { ForEach(Pane.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14).padding(.bottom, 6)
                switch pane {
                case .queue: QueueView(close: {}, showsBack: false)
                case .lyrics: LyricsView(close: { pane = .queue })
                }
            }
            .background { AmbientArt(url: player.current?.artURL(size: 300)).ignoresSafeArea() }
            .navigationSplitViewColumnWidth(min: 390, ideal: 410)
        }
        .sheet(item: $coverAlbum) { a in
            ScrollView {
                CoverPicker(album: a, artist: a.parts == nil ? a.artist : "") { _ in coverAlbum = nil }
            }
            .frame(width: 520, height: 480)
        }
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).opacity(0)
        }
    }
}
