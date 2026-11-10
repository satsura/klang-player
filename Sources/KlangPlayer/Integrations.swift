import AppKit
import Combine
import MediaPlayer
import WidgetKit

/// Mirrors player state to: menu bar title + buttons, macOS Now Playing (media keys),
/// the local /api/state endpoint and the widget.
@MainActor
final class Integrations {
    static let shared = Integrations()

    private let player = Player.shared
    private var bag = Set<AnyCancellable>()
    private var titleItem: NSStatusItem?
    private var prevItem: NSStatusItem?
    private var playItem: NSStatusItem?
    private var nextItem: NSStatusItem?

    private var artTrackId: String?
    private var artImage: NSImage?
    private var lastTrackId: String?
    private var lastState: Player.State?

    static var showInMenuBar: Bool {
        get { UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showInMenuBar"); Integrations.shared.update() }
    }

    func start() {
        setupRemoteCommands()
        player.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &bag)
        FileServer.shared.api = { method, path in Integrations.handleAPI(method, path) }
        update()
    }

    // MARK: Update

    func update() {
        let t = player.current
        let changed = t?.Id != lastTrackId || player.state != lastState
        lastTrackId = t?.Id
        lastState = player.state

        updateMenuBar()
        updateNowPlaying()
        mirrorState()
        if changed {
            loadArt()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: Menu bar

    private func updateMenuBar() {
        let show = Integrations.showInMenuBar && player.current != nil
        if show, titleItem == nil {
            // Each new item goes to the left of the previous ones: next, play, prev, title.
            nextItem = makeButton("forward.fill", #selector(MenuTarget.next))
            playItem = makeButton("play.fill", #selector(MenuTarget.toggle))
            prevItem = makeButton("backward.fill", #selector(MenuTarget.prev))
            let ti = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            ti.button?.target = MenuTarget.shared
            ti.button?.action = #selector(MenuTarget.card)
            ti.button?.toolTip = String(localized: "Show card")
            titleItem = ti
        } else if !show, titleItem != nil {
            for i in [titleItem, prevItem, playItem, nextItem] { if let i { NSStatusBar.system.removeStatusItem(i) } }
            titleItem = nil; prevItem = nil; playItem = nil; nextItem = nil
        }
        guard show, let t = player.current else { return }
        var title = [t.artist, t.Name].filter { !$0.isEmpty }.joined(separator: " — ")
        if title.count > 38 { title = String(title.prefix(37)) + "…" }
        titleItem?.button?.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: player.state == .playing ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        let playing = player.state == .playing || player.state == .preparing
        playItem?.button?.image = symbol(playing ? "pause.fill" : "play.fill")
        nextItem?.button?.appearsDisabled = player.upcoming.isEmpty
    }

    private func makeButton(_ name: String, _ action: Selector) -> NSStatusItem {
        let i = NSStatusBar.system.statusItem(withLength: 22)
        i.button?.image = symbol(name)
        i.button?.target = MenuTarget.shared
        i.button?.action = action
        return i
    }

    private func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        img?.isTemplate = true
        return img
    }

    // MARK: Now Playing / media keys

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in Task { @MainActor in if Player.shared.state != .playing { Player.shared.toggle() } }; return .success }
        c.pauseCommand.addTarget { _ in Task { @MainActor in if Player.shared.state == .playing { Player.shared.toggle() } }; return .success }
        c.togglePlayPauseCommand.addTarget { _ in Task { @MainActor in Player.shared.toggle() }; return .success }
        c.nextTrackCommand.addTarget { _ in Task { @MainActor in Player.shared.next() }; return .success }
        c.previousTrackCommand.addTarget { _ in Task { @MainActor in Player.shared.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in Player.shared.seek(to: t) }
            return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = player.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.Name,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.Album ?? "",
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position,
            MPNowPlayingInfoPropertyPlaybackRate: player.state == .playing ? 1.0 : 0.0,
        ]
        if let img = artImage, artTrackId == t.Id {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        center.nowPlayingInfo = info
        center.playbackState = switch player.state {
        case .playing, .preparing: .playing
        case .paused: .paused
        case .idle: .stopped
        }
    }

    private func loadArt() {
        guard let t = player.current, t.Id != artTrackId else { return }
        let id = t.Id
        guard let url = Emby.shared.imageURL(itemId: t.AlbumId, tag: t.AlbumPrimaryImageTag, size: 600) else {
            artTrackId = id; artImage = nil; artData = nil
            return
        }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = NSImage(data: data), player.current?.Id == id else { return }
            artTrackId = id
            artImage = img
            artData = data
            updateNowPlaying()
            mirrorState()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: Local API (for the widget)

    private var artData: Data?
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var stateJSON = Data("{}".utf8)
    nonisolated(unsafe) private static var art: Data?

    private func mirrorState() {
        let t = player.current
        let state: String = switch player.state {
        case .playing: "playing"
        case .paused: "paused"
        case .preparing: "preparing"
        case .idle: "idle"
        }
        let obj: [String: Any] = [
            "title": t?.Name ?? "",
            "artist": t?.artist ?? "",
            "album": t?.Album ?? "",
            "state": state,
            "position": player.position,
            "duration": player.duration,
            "hasNext": !player.upcoming.isEmpty,
            "volume": Int(player.volume),
            "maxVolume": Int(player.maxVolume),
            "artId": artTrackId == t?.Id ? (t?.Id ?? "") : "",
        ]
        let json = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let art = artTrackId == t?.Id ? artData : nil
        Integrations.lock.lock()
        Integrations.stateJSON = json
        Integrations.art = art
        Integrations.lock.unlock()
    }

    /// Runs on the file server queue.
    nonisolated static func handleAPI(_ method: String, _ path: String) -> (Int, String, Data) {
        switch path {
        case "/api/state":
            lock.lock(); defer { lock.unlock() }
            return (200, "application/json", stateJSON)
        case "/api/art":
            lock.lock(); defer { lock.unlock() }
            guard let art else { return (404, "text/plain", Data()) }
            return (200, "image/jpeg", art)
        case "/api/toggle", "/api/next", "/api/prev":
            guard method == "POST" else { return (405, "text/plain", Data()) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch path {
                    case "/api/toggle": Player.shared.toggle()
                    case "/api/next": Player.shared.next()
                    default: Player.shared.previous()
                    }
                }
            }
            return (204, "text/plain", Data())
        default:
            return (404, "text/plain", Data())
        }
    }
}

/// Target for status bar buttons.
@MainActor
final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    @objc func toggle() { Player.shared.toggle() }
    @objc func next() { Player.shared.next() }
    @objc func prev() { Player.shared.previous() }
    @objc func card() { MiniPlayer.shared.toggle() }
}
