import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var lib = Library.shared
    let showQueue: () -> Void
    let showLyrics: () -> Void
    let pickCover: (Album) -> Void
    @ObservedObject private var lyrics = LyricsStore.shared
    @State private var hoverCover = false

    private var art: URL? {
        player.current?.artURL(size: 300)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Cover(url: art, size: 76, radius: 8, placeholder: "hifispeaker")
                    .overlay(alignment: .bottomLeading) {
                        if let t = player.current {
                            CoverBadges(hiRes: t.isHiRes, lyrics: lyrics.known[t.Id] == true ? (1, 1) : nil)
                                .pressable(showLyrics)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if hoverCover, let t = player.current, let a = lib.album(for: t) {
                            GlassIconButton(icon: "arrow.triangle.2.circlepath", label: "Find another cover",
                                            size: 22, symbolSize: 9, overImage: true) { pickCover(a) }
                                .padding(3)
                        }
                    }
                    .onHover { hoverCover = $0 }
                    .task(id: player.current?.Id) {
                        if let t = player.current { _ = await LyricsStore.shared.lyrics(for: t) }
                    }
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Marquee(text: player.current?.Name ?? String(localized: "Nothing playing"),
                            font: .system(size: 14, weight: .semibold))
                    Marquee(text: subtitle, font: .system(size: 12))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        if player.state == .preparing {
                            ProgressView().controlSize(.mini)
                            Group {
                                switch player.preparePhase {
                                case .downloading(let f): Text("Downloading \(Int(f * 100))%")
                                case .converting: Text("Converting to AAC…")
                                case nil: Text("preparing…")
                                }
                            }
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                        } else if let t = player.current {
                            Badge(text: t.sourceLabel)
                            if let o = player.outputLabel {
                                Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                                Badge(text: o)
                            }
                        }
                    }
                    .frame(height: 16)
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                if let t = player.current {
                    FavoriteButton(track: t).font(.system(size: 15))
                }
            }

            PositionSlider()

            HStack(spacing: 8) {
                volume.frame(maxWidth: .infinity, alignment: .leading)
                transport
                tools.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(14)
    }

    /// ⏮ ⏯ ⏭ as glass circles that blend into each other.
    private var transport: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 6) {
                GlassIconButton(icon: "backward.fill", label: "Previous", size: 32) { player.previous() }
                GlassIconButton(icon: player.state == .playing ? "pause.fill" : "play.fill",
                                label: player.state == .playing ? "Pause" : "Play",
                                size: 44, symbolSize: 17, prominent: true) { player.toggle() }
                GlassIconButton(icon: "forward.fill", label: "Next", size: 32) { player.next() }
                    .disabled(!player.hasNext)
            }
        }
        .disabled(player.current == nil)
    }

    /// Lyrics, sleep timer, floating card and queue in one glass capsule.
    private var tools: some View {
        HStack(spacing: 9) {
            Button(action: showLyrics) { Image(systemName: "quote.bubble") }
                .tip("Lyrics")
            SleepButton()
            Button { MiniPlayer.shared.toggle() } label: { Image(systemName: "pip") }
                .tip("Floating card")
            Button(action: showQueue) {
                HStack(spacing: 3) {
                    Image(systemName: "list.bullet")
                    if !player.upcoming.isEmpty { Text("\(player.upcoming.count)").font(.system(size: 10).monospacedDigit()) }
                }
            }
            .tip("Queue")
            .accessibilityValue(player.upcoming.isEmpty ? Text(verbatim: "") : Text("\(player.upcoming.count) next"))
        }
        .font(.system(size: 12))
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .glass(Capsule())
        .fixedSize()
    }

    private var volume: some View {
        HStack(spacing: 5) {
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...player.maxVolume)
                .controlSize(.mini)
        }
        .frame(maxWidth: 120)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .glass(Capsule())
        .help("Speaker volume: \(Int(player.volume))")
    }

    private var subtitle: String {
        guard let t = player.current else {
            return Config.speakerName.isEmpty ? String(localized: "Pick something to play below") : Config.speakerName
        }
        return [t.artist, t.Album ?? ""].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

struct QueueView: View {
    @ObservedObject var player = Player.shared
    @Environment(\.undoManager) private var undo
    let close: () -> Void
    var showsBack = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if showsBack {
                    Button(action: close) {
                        Image(systemName: "chevron.left").hitTarget().font(.system(size: 12, weight: .semibold))
                    }
                    .accessibilityLabel(Text("Back"))
                }
                Text("Queue").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { player.undoable(String(localized: "Shuffle"), undo) { player.shuffleUpcoming() } } label: { Image(systemName: "shuffle").hitTarget() }
                    .tip("Shuffle what's next")
                    .disabled(player.upcoming.count < 2)
                Button { player.cycleRepeat() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").hitTarget()
                        .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                }
                .tip(player.repeatMode == .off ? LocalizedStringKey("Repeat: off") : player.repeatMode == .all ? LocalizedStringKey("Repeat: queue") : LocalizedStringKey("Repeat: track"))
                Button { player.setAutoplay(!player.autoplay) } label: {
                    Image(systemName: "infinity").hitTarget()
                        .foregroundStyle(player.autoplay ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                }
                .tip(player.autoplay ? LocalizedStringKey("When the queue ends: similar music (on)") : LocalizedStringKey("When the queue ends: stop"))
                Menu {
                    Button("Save as Playlist…") { Task { await Library.shared.addToPlaylist(nil, tracks: player.queue) } }
                        .disabled(player.queue.isEmpty)
                    AddToPlaylistMenu { player.queue }
                    Divider()
                    Button("Clear What's Next") { player.undoable(String(localized: "Clear What's Next"), undo) { player.clearUpcoming() } }.disabled(player.upcoming.isEmpty)
                    Button("Clear Queue") { player.undoable(String(localized: "Clear Queue"), undo) { player.clearAll() } }.disabled(player.queue.isEmpty)
                } label: { Image(systemName: "ellipsis.circle").hitTarget() }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if player.queue.isEmpty {
                EmptyState(icon: "list.bullet", text: String(localized: "Queue is empty"))
                    .dropDestination(for: DragItems.self) { items, _ in
                        Task { player.play(await DragItems.tracks(items)) }
                        return true
                    }
            } else {
                ScrollViewReader { proxy in
                    // List: drag tracks to reorder.
                    List {
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { i, t in
                            TrackRow(track: t, showArtist: true, showCover: true,
                                     onRemove: i == player.index ? nil : { player.undoable(String(localized: "Remove from Queue"), undo) { player.remove(at: i) } },
                                     dragsOut: false) { player.jump(to: i) }
                                .opacity(i < player.index ? 0.45 : 1)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .id(i)
                        }
                        .onMove { from, to in player.undoable(String(localized: "Move"), undo) { player.move(from: from, to: to) } }
                        // Albums and tracks dragged from the library go in where they're dropped.
                        .dropDestination(for: DragItems.self) { items, offset in
                            Task {
                                let tracks = await DragItems.tracks(items)
                                guard !tracks.isEmpty else { return }
                                player.undoable(String(localized: "Add to Queue"), undo) { player.insert(tracks, at: offset) }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onAppear { proxy.scrollTo(max(0, player.index), anchor: .top) }
                }
            }
        }
    }
}

/// Moon button with the sleep timer menu and the time left.
struct SleepButton: View {
    @ObservedObject var player = Player.shared

    var body: some View {
        Menu {
            ForEach([15, 30, 45, 60, 120], id: \.self) { m in
                Button("\(m) min") { player.setSleepTimer(minutes: m) }
            }
            Button("After this track") { player.setSleepAfterTrack() }
            if player.sleepAt != nil || player.sleepAfterTrack {
                Divider()
                Button("Turn Off Timer") { player.setSleepTimer(minutes: nil) }
            }
        } label: {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                HStack(spacing: 2) {
                    Image(systemName: player.sleepAt != nil || player.sleepAfterTrack ? "moon.zzz.fill" : "moon.zzz")
                    if let at = player.sleepAt {
                        Text(verbatim: "\(max(1, Int(at.timeIntervalSinceNow / 60) + 1))'")
                            .font(.system(size: 10).monospacedDigit())
                    }
                }
                .foregroundStyle(player.sleepAt != nil || player.sleepAfterTrack ? Color.accentColor : .primary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tip("Sleep timer")
    }
}

/// Seek slider and times. Observes only the playback clock, so the rest of the window
/// doesn't redraw every second.
private struct PositionSlider: View {
    @ObservedObject var clock = Player.shared.clock
    @State private var scrub: Double?
    private var player: Player { .shared }

    var body: some View {
        VStack(spacing: 1) {
            Slider(value: Binding(get: { scrub ?? clock.position }, set: { scrub = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                player.setScrubbing(editing)
                if !editing, let s = scrub {
                    player.seek(to: s)
                    scrub = nil
                }
            }
            .controlSize(.mini)
            .disabled(player.current == nil || player.state == .preparing)
            .accessibilityLabel(Text("Position"))
            .accessibilityValue(Text("\(mmss(scrub ?? clock.position)) of \(mmss(player.duration))"))
            HStack {
                Text(mmss(scrub ?? clock.position))
                Spacer()
                Text("-" + mmss(max(0, player.duration - (scrub ?? clock.position))))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

/// ♥ for a track: Emby favorite, and love on Last.fm when it's connected.
struct FavoriteButton: View {
    @ObservedObject var lib = Library.shared
    let track: Track

    var body: some View {
        let on = lib.isFavorite(track.Id, server: track.isFavorite)
        Button { lib.toggleFavorite(track) } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .foregroundStyle(on ? Color.pink : .secondary)
        }
        .buttonStyle(.borderless)
        .help(on ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Add to Favorites"))
        .accessibilityLabel(on ? Text("Remove from Favorites") : Text("Add to Favorites"))
    }
}
