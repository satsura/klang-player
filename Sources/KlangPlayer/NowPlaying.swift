import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player = Player.shared
    let showQueue: () -> Void
    @State private var scrub: Double?

    private var art: URL? {
        player.current?.artURL(size: 300)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Cover(url: art, size: 76, radius: 8, placeholder: "hifispeaker")
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
            }

            VStack(spacing: 1) {
                Slider(value: Binding(get: { scrub ?? player.position }, set: { scrub = $0 }),
                       in: 0...max(player.duration, 1)) { editing in
                    player.setScrubbing(editing)
                    if !editing, let s = scrub {
                        player.seek(to: s)
                        scrub = nil
                    }
                }
                .controlSize(.mini)
                .disabled(player.current == nil || player.state == .preparing)
                HStack {
                    Text(mmss(scrub ?? player.position))
                    Spacer()
                    Text("-" + mmss(max(0, player.duration - (scrub ?? player.position))))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack {
                volume.frame(width: 110)
                Spacer()
                HStack(spacing: 18) {
                    Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 15)) }
                    Button { player.toggle() } label: {
                        Image(systemName: player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34))
                            .symbolRenderingMode(.hierarchical)
                    }
                    Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 15)) }
                        .disabled(player.upcoming.isEmpty)
                }
                .buttonStyle(.borderless)
                .disabled(player.current == nil)
                Spacer()
                HStack(spacing: 12) {
                    SleepButton()
                    Button { MiniPlayer.shared.toggle() } label: { Image(systemName: "pip") }
                        .help("Floating card")
                    Button(action: showQueue) {
                        HStack(spacing: 3) {
                            Image(systemName: "list.bullet")
                            if !player.upcoming.isEmpty { Text("\(player.upcoming.count)").font(.system(size: 10).monospacedDigit()) }
                        }
                    }
                    .help("Queue")
                }
                .buttonStyle(.borderless)
                .frame(width: 110, alignment: .trailing)
            }
        }
        .padding(14)
        .background {
            ZStack {
                if player.current != nil {
                    AsyncImage(url: art) { $0.image?.resizable().aspectRatio(contentMode: .fill) }
                        .id(art)
                        .blur(radius: 40)
                        .opacity(0.45)
                }
                LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.6)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .clipped()
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
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: close) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                Text("Queue").font(.system(size: 12, weight: .semibold))
                Spacer()
                if !player.upcoming.isEmpty {
                    Button("Clear") { player.clearUpcoming() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if player.queue.isEmpty {
                EmptyState(icon: "list.bullet", text: String(localized: "Queue is empty"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(player.queue.enumerated()), id: \.offset) { i, t in
                                TrackRow(track: t, showArtist: true, showCover: true,
                                         onRemove: i == player.index ? nil : { player.remove(at: i) }) { player.jump(to: i) }
                                    .opacity(i < player.index ? 0.45 : 1)
                                    .id(i)
                            }
                        }
                        .padding(.vertical, 6)
                    }
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
        .help("Sleep timer")
    }
}
