import SwiftUI
import WidgetKit

// Desktop / Notification Center widget. Reads state from the app's local API
// (http://127.0.0.1:47830/api/state) and controls it through klangplayer:// links.

private let api = "http://127.0.0.1:47830/api"

struct NowEntry: TimelineEntry {
    let date: Date
    var title = ""
    var artist = ""
    var album = ""
    var state = "idle"
    var hasNext = false
    var art: NSImage?
    var online = true

    var playing: Bool { state == "playing" || state == "preparing" }

    static let sample = NowEntry(date: .now, title: "Falling, Catching", artist: "Agnes Obel", album: "Philharmonics", state: "playing")
    static let offline = NowEntry(date: .now, online: false)
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> NowEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (NowEntry) -> Void) {
        Task { completion(await fetch() ?? .sample) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowEntry>) -> Void) {
        Task {
            let e = await fetch() ?? .offline
            // The app asks WidgetKit to reload on every track/state change; this is just a fallback.
            completion(Timeline(entries: [e], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }

    private func fetch() async -> NowEntry? {
        guard let (data, _) = try? await URLSession.shared.data(from: URL(string: api + "/state")!),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var e = NowEntry(date: .now)
        e.title = o["title"] as? String ?? ""
        e.artist = o["artist"] as? String ?? ""
        e.album = o["album"] as? String ?? ""
        e.state = o["state"] as? String ?? "idle"
        e.hasNext = o["hasNext"] as? Bool ?? false
        if let artId = o["artId"] as? String, !artId.isEmpty,
           let (img, _) = try? await URLSession.shared.data(from: URL(string: api + "/art")!) {
            e.art = NSImage(data: img)
        }
        return e
    }
}

private func link(_ action: String) -> URL { URL(string: "klangplayer://\(action)")! }

struct Artwork: View {
    let image: NSImage?
    var body: some View {
        if let image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.3), Color(white: 0.15)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "hifispeaker").font(.system(size: 26)).foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}

struct SmallView: View {
    let e: NowEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer()
            Text(e.title.isEmpty ? "Klang Player" : e.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            Text(e.online ? (e.artist.isEmpty ? String(localized: "Nothing playing") : e.artist) : String(localized: "App is not running"))
                .font(.system(size: 11))
                .opacity(0.8)
                .lineLimit(1)
            HStack {
                Spacer()
                Image(systemName: e.playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 22))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 3)
        .widgetURL(link("toggle"))
        .containerBackground(for: .widget) {
            ZStack {
                Artwork(image: e.art)
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            }
        }
    }
}

struct MediumView: View {
    let e: NowEntry
    var body: some View {
        HStack(spacing: 14) {
            Artwork(image: e.art)
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title.isEmpty ? "Klang Player" : e.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Text(e.online ? (e.artist.isEmpty ? String(localized: "Nothing playing") : e.artist) : String(localized: "App is not running"))
                    .font(.system(size: 12))
                    .opacity(0.8)
                    .lineLimit(1)
                if !e.album.isEmpty {
                    Text(e.album).font(.system(size: 11)).opacity(0.6).lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(spacing: 22) {
                    Link(destination: link("prev")) { Image(systemName: "backward.fill") }
                    Link(destination: link("toggle")) {
                        Image(systemName: e.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 28))
                    }
                    Link(destination: link("next")) { Image(systemName: "forward.fill") }
                        .opacity(e.hasNext ? 1 : 0.4)
                }
                .font(.system(size: 15))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            ZStack {
                Artwork(image: e.art).blur(radius: 30)
                Color.black.opacity(0.45)
            }
        }
    }
}

struct KlangWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: NowEntry
    var body: some View {
        switch family {
        case .systemSmall: SmallView(e: entry)
        default: MediumView(e: entry)
        }
    }
}

struct KlangNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KlangNowPlaying", provider: Provider()) { KlangWidgetView(entry: $0) }
            .configurationDisplayName("Klang Player")
            .description("What's playing on the speaker")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct KlangWidgets: WidgetBundle {
    var body: some Widget { KlangNowPlayingWidget() }
}
