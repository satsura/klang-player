import AppKit
import SwiftUI

/// The large, resizable window: sidebar, library, and now playing with queue / lyrics.
@MainActor
final class LibraryWindow: NSObject, NSWindowDelegate {
    static let shared = LibraryWindow()
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func close() { window?.close() }

    func show(activate: Bool = true) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 740),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Klang Player"
            w.toolbarStyle = .unified
            w.contentMinSize = NSSize(width: 1000, height: 560)
            w.isReleasedWhenClosed = false
            w.delegate = self
            let host = NSHostingController(rootView: LibraryWindowView())
            // SwiftUI's .toolbar, .searchable and .navigationTitle go to this window.
            host.sceneBridgingOptions = [.toolbars, .title]
            w.contentViewController = host
            if !w.setFrameUsingName("KlangLibraryWindow") { w.center() }
            w.setFrameAutosaveName("KlangLibraryWindow")
            window = w
        }
        guard activate else { window?.orderFrontRegardless(); return }   // debug screenshots
        // While the window is open the app shows in the Dock and ⌘Tab.
        Presence.hiddenToMenuBar = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // The window still counts as visible here.
        DispatchQueue.main.async { Presence.updateDock() }
    }
}

struct LibraryWindowView: View {
    @ObservedObject private var player = Player.shared
    @AppStorage("appMode") private var mode = AppMode.both.rawValue
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
                    .tip("Settings")
                    Spacer()
                    if AppMode(rawValue: mode)?.usesMenuBar ?? true {
                        Button { Presence.hideToMenuBar() } label: { Image(systemName: "menubar.arrow.up.rectangle") }
                            .tip("Hide to Menu Bar")
                    }
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
        } content: {
            BrowserView(state: nav, compact: false, searchFocused: $searchFocused)
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
                .navigationTitle(nav.title)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button { nav.pop() } label: { Image(systemName: "chevron.left") }
                            .tip("Back")
                            .keyboardShortcut("[", modifiers: .command)
                            .disabled(!nav.canGoBack)
                        Button { nav.goForward() } label: { Image(systemName: "chevron.right") }
                            .tip("Forward")
                            .keyboardShortcut("]", modifiers: .command)
                            .disabled(!nav.canGoForward)
                    }
                }
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
        .searchable(text: $nav.query, placement: .toolbar, prompt: Text("Search"))
        .modifier(SearchFocus(focused: $searchFocused))
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
        // Space plays / pauses unless a text field takes it.
        .onKeyPress(.space) {
            guard player.current != nil, !(NSApp.keyWindow?.firstResponder is NSText) else { return .ignored }
            player.toggle()
            return .handled
        }
    }
}

/// ⌘F into the toolbar search (macOS 15+; before that a click on the field).
private struct SearchFocus: ViewModifier {
    var focused: FocusState<Bool>.Binding
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.searchFocused(focused) } else { content }
    }
}
