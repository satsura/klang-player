import SwiftUI

struct Cover: View {
    let url: URL?
    let size: CGFloat
    var radius: CGFloat? = nil
    var placeholder = "music.note"

    var body: some View {
        AsyncImage(url: url) { phase in
            if let img = phase.image {
                img.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color.secondary.opacity(0.18), Color.secondary.opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: placeholder)
                        .font(.system(size: size * 0.32))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius ?? max(4, size * 0.08), style: .continuous))
    }
}

struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(.secondary)
            .overlay(Capsule().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.8))
    }
}

/// Row highlight on hover + whole-row hit area.
struct Hoverable: ViewModifier {
    @State private var hover = false
    var active = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(0.14) : hover ? Color.primary.opacity(0.06) : .clear)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

extension View {
    func hoverable(active: Bool = false) -> some View { modifier(Hoverable(active: active)) }
}

struct NavHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.leftArrow, modifiers: .command)
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

struct EmptyState: View {
    let icon: String
    let text: String
    var action: (title: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action { Button(action.title, action: action.run).controlSize(.small) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Track list row used in albums, folders and search.
struct TrackRow: View {
    @ObservedObject var player = Player.shared
    let track: Track
    var number: Int? = nil
    var showArtist = false
    var showCover = false
    var onRemove: (() -> Void)? = nil
    let play: () -> Void

    @State private var hover = false

    private var isCurrent: Bool { player.current?.Id == track.Id }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if showCover {
                    Cover(url: Emby.shared.imageURL(itemId: track.AlbumId, tag: track.AlbumPrimaryImageTag, size: 80), size: 30)
                        .opacity(hover ? 0.35 : 1)
                }
                if hover {
                    Image(systemName: "play.fill").font(.system(size: 10))
                } else if isCurrent {
                    Image(systemName: player.state == .playing ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                } else if !showCover {
                    Text(number.map(String.init) ?? "·")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: showCover ? 30 : 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.Name)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                if showArtist {
                    Text([track.artist, track.Album ?? ""].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(mmss(track.duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, showArtist ? 4 : 5)
        .hoverable(active: isCurrent)
        .onHover { hover = $0 }
        .onTapGesture(count: 1, perform: play)
        .contextMenu {
            Button("Играть") { play() }
            Button("Играть далее") { player.playNext([track]) }
            Button("Добавить в очередь") { player.enqueue([track]) }
            if let onRemove {
                Divider()
                Button("Убрать из очереди", action: onRemove)
            }
        }
    }
}
