import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player = Player.shared
    let showQueue: () -> Void
    @State private var scrub: Double?

    private var art: URL? {
        Emby.shared.imageURL(itemId: player.current?.AlbumId, tag: player.current?.AlbumPrimaryImageTag, size: 300)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Cover(url: art, size: 76, radius: 8, placeholder: "hifispeaker")
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.current?.Name ?? "Ничего не играет")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if player.state == .preparing {
                            ProgressView().controlSize(.mini)
                            Text("готовлю…").font(.system(size: 10)).foregroundStyle(.secondary)
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
                Button(action: showQueue) {
                    HStack(spacing: 3) {
                        Image(systemName: "list.bullet")
                        if !player.upcoming.isEmpty { Text("\(player.upcoming.count)").font(.system(size: 10).monospacedDigit()) }
                    }
                }
                .buttonStyle(.borderless)
                .help("Очередь")
                .frame(width: 110, alignment: .trailing)
            }
        }
        .padding(14)
        .background {
            ZStack {
                if player.current != nil {
                    AsyncImage(url: art) { $0.image?.resizable().aspectRatio(contentMode: .fill) }
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
            Slider(value: $player.volume, in: 0...player.maxVolume)
                .controlSize(.mini)
                .onChange(of: player.volume) { player.volumeChanged() }
        }
        .help("Громкость колонки: \(Int(player.volume))")
    }

    private var subtitle: String {
        guard let t = player.current else {
            return Config.speakerName.isEmpty ? "Выбери музыку ниже" : Config.speakerName
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
                Text("Очередь").font(.system(size: 12, weight: .semibold))
                Spacer()
                if !player.upcoming.isEmpty {
                    Button("Очистить") { player.clearUpcoming() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if player.queue.isEmpty {
                EmptyState(icon: "list.bullet", text: "Очередь пуста")
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
