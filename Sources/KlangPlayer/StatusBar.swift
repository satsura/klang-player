import AppKit
import Combine
import SwiftUI

/// Menu bar: the title item (speaker icon + current track) opens the main window (a popover),
/// right click shows a menu; ⏮ ⏯ ⏭ are separate items next to it. They have to be separate:
/// macOS reports a click on a menu bar item without the point inside it, so one item can't
/// hold several buttons.
@MainActor
final class StatusBar: NSObject, NSPopoverDelegate {
    static let shared = StatusBar()

    private var titleItem: NSStatusItem?
    private var controls: [(item: NSStatusItem, kind: Control)] = []
    private var host: ClickThroughHostingView<StatusBarView>?
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()

    private enum Control { case previous, toggle, next }
    /// Off in the "window only" mode: the items stay created but hidden.
    private var active = false

    func start() {
        active = true
        if let titleItem {
            titleItem.isVisible = true
            resize()
            return
        }
        // A newly created item appears left of the ones before it: ⏭ ⏯ ⏮ first, the title last.
        for kind in [Control.next, .toggle, .previous] {
            // Narrow items: the menu bar adds its own gap between items.
            let it = NSStatusBar.system.statusItem(withLength: kind == .toggle ? 20 : 18)
            it.autosaveName = "KlangPlayer.button.\(kind)"
            it.button?.target = self
            it.button?.action = #selector(controlClicked(_:))
            it.button?.imageScaling = .scaleNone
            controls.append((it, kind))
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "KlangPlayer.nowPlaying"
        titleItem = item
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(titleClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Draws only; the click goes to the status bar button underneath.
        let host = ClickThroughHostingView(rootView: StatusBarView())
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.topAnchor.constraint(equalTo: button.topAnchor),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        self.host = host


        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ContentView()
            .task { if Library.shared.albums.isEmpty { await Library.shared.load() } })

        Player.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resize() }
            .store(in: &bag)
        resize()
    }

    /// Hides all menu bar items (they keep their places for the next start).
    func stop() {
        active = false
        if popover.isShown { popover.performClose(nil) }
        titleItem?.isVisible = false
        for (it, _) in controls { it.isVisible = false }
    }

    /// Fits the title item to its content and updates the control items.
    func resize() {
        guard active else { return }
        guard let host else { return }
        host.invalidateIntrinsicContentSize()
        titleItem?.length = max(24, host.fittingSize.width)

        let p = Player.shared
        let show = StatusBarView.showsTrack
        for (it, kind) in controls {
            it.isVisible = show
            guard show, let b = it.button else { continue }
            let symbol: String
            switch kind {
            case .previous: symbol = "backward.fill"
            case .toggle: symbol = p.state == .playing || p.state == .preparing ? "pause.fill" : "play.fill"
            case .next: symbol = "forward.fill"
            }
            let label = switch kind {
            case .previous: String(localized: "Previous")
            case .toggle: p.state == .playing ? String(localized: "Pause") : String(localized: "Play")
            case .next: String(localized: "Next")
            }
            // Play/pause is the main control: larger; skip buttons smaller and lighter.
            let config = kind == .toggle
                ? NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                : NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(config)
            img?.isTemplate = true
            if b.image?.name() != symbol { b.image = img; b.image?.setName(symbol) }
            b.toolTip = label
            b.appearsDisabled = kind == .next && !p.hasNext
            b.alphaValue = kind == .toggle ? 1 : 0.85
        }
    }

    func togglePopover() {
        guard let button = titleItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func showPopover() { if !popover.isShown { togglePopover() } }

    /// Closes the popover and opens the large window (at a tab if given).
    func openWindow(_ tab: Tab? = nil) {
        if popover.isShown { popover.performClose(nil) }
        Presence.showWindow()
        if let tab { LibraryWindow.shared.nav.show(tab) }
    }

    @objc private func titleClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            showMenu(sender)
        } else {
            togglePopover()
        }
    }

    @objc private func controlClicked(_ sender: NSStatusBarButton) {
        guard let kind = controls.first(where: { $0.item.button === sender })?.kind else { return }
        let p = Player.shared
        switch kind {
        case .previous: p.previous()
        case .toggle: p.toggle()
        case .next: p.next()
        }
    }

    private func showMenu(_ button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(MenuAction(title: String(localized: "Open Klang Player")) { [weak self] in self?.showPopover() })
        menu.addItem(MenuAction(title: String(localized: "Open in Window")) { [weak self] in self?.openWindow() })
        menu.addItem(MenuAction(title: MiniPlayer.shared.isVisible ? String(localized: "Close Card") : String(localized: "Show card")) {
            MiniPlayer.shared.toggle()
        })
        if let t = Player.shared.current {
            let on = Library.shared.currentIsFavorite
            let fav = MenuAction(title: on ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")) {
                Library.shared.toggleFavorite(t)
            }
            fav.image = NSImage(systemSymbolName: on ? "heart.fill" : "heart", accessibilityDescription: nil)
            menu.addItem(fav)
        }
        if Speaker.shared.canPower {
            menu.addItem(MenuAction(title: String(localized: "Turn Off Speaker")) { Player.shared.turnOffSpeaker() })
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction(title: String(localized: "Quit")) { NSApp.terminate(nil) })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }
}

/// Draws SwiftUI content but lets every click fall through to the view below (the status bar button).
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Menu item that runs a closure.
final class MenuAction: NSMenuItem {
    private let run: () -> Void
    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// What the menu bar shows while something is in the queue.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case full, controls, icon
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .full: "Cover, track and buttons"
        case .controls: "Cover and buttons"
        case .icon: "Icon only"
        }
    }

    static var current: MenuBarStyle {
        get {
            if let raw = UserDefaults.standard.string(forKey: "menuBarStyle"), let s = MenuBarStyle(rawValue: raw) { return s }
            // Older setting: a track-and-buttons on/off toggle.
            return UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true ? .full : .icon
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "menuBarStyle")
            MainActor.assumeIsolated { StatusBar.shared.resize() }
        }
    }
}

/// Title item content: the cover (speaker icon) and the current track (scrolls when long).
struct StatusBarView: View {
    @ObservedObject var player = Player.shared
    @AppStorage("menuBarStyle") private var styleRaw = ""
    private var style: MenuBarStyle { MenuBarStyle(rawValue: styleRaw) ?? .current }

    /// Whether the ⏮ ⏯ ⏭ items are shown.
    static var showsTrack: Bool { MenuBarStyle.current != .icon && Player.shared.current != nil }

    private var title: String? {
        guard style == .full, let t = player.current else { return nil }
        return [t.artist, t.Name].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    private var speakerIcon: some View {
        Image(systemName: player.state == .playing ? "hifispeaker.fill" : "hifispeaker")
            .font(.system(size: 13))
    }

    /// Longer titles scroll inside this width.
    private static let maxTitleWidth: CGFloat = 240
    private func width(of s: String) -> CGFloat {
        let w = (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        return min(ceil(w) + 1, Self.maxTitleWidth)
    }

    var body: some View {
        HStack(spacing: 6) {
            if style != .icon, let art = player.current?.artURL(size: 64) {
                // Small cover of the current album; the speaker icon until it loads.
                AsyncImage(url: art) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        speakerIcon
                    }
                }
                .id(art)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .opacity(player.state == .playing ? 1 : 0.7)
            } else {
                speakerIcon
            }
            if let title {
                Marquee(text: title, font: .system(size: 13), active: player.state == .playing)
                    .frame(width: width(of: title))
                    .opacity(player.state == .playing ? 1 : 0.6)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
        .allowsHitTesting(false)
    }
}
