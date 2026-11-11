import AppKit
import SwiftUI

enum CardStyle: String, CaseIterable {
    case cover      // cover with title and buttons
    case art        // cover only; title and buttons on hover
    case strip      // small horizontal bar

    var title: LocalizedStringKey {
        switch self {
        case .cover: "Cover with Controls"
        case .art: "Cover Only"
        case .strip: "Strip"
        }
    }
}

enum CardSize: String, CaseIterable {
    case small, medium, large

    var title: LocalizedStringKey {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    fileprivate func frame(for style: CardStyle) -> NSSize {
        switch (style, self) {
        case (.strip, .small): NSSize(width: 260, height: 60)
        case (.strip, .medium): NSSize(width: 340, height: 76)
        case (.strip, .large): NSSize(width: 440, height: 96)
        case (_, .small): NSSize(width: 200, height: 200)
        case (_, .medium): NSSize(width: 300, height: 300)
        case (_, .large): NSSize(width: 440, height: 440)
        }
    }
}

/// Floating card above all windows. A non-activating panel: it never takes focus or keyboard input.
@MainActor
final class MiniPlayer: ObservableObject {
    static let shared = MiniPlayer()

    @Published private(set) var style = CardStyle(rawValue: UserDefaults.standard.string(forKey: "cardStyle") ?? "") ?? .cover
    @Published private(set) var size = CardSize(rawValue: UserDefaults.standard.string(forKey: "cardSize") ?? "") ?? .medium

    private var panel: NSPanel?
    private var scrollMonitor: Any?
    private var scrollAccum: CGFloat = 0
    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: "miniPlayerOpen")
    }

    func hide() {
        panel?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: "miniPlayerOpen")
    }

    func restore() {
        if UserDefaults.standard.bool(forKey: "miniPlayerOpen") { show() }
    }

    func setStyle(_ s: CardStyle) {
        style = s
        UserDefaults.standard.set(s.rawValue, forKey: "cardStyle")
        applyLayout(resize: true)
    }

    func setSize(_ z: CardSize) {
        size = z
        UserDefaults.standard.set(z.rawValue, forKey: "cardSize")
        applyLayout(resize: true)
    }

    /// Resize limits for the style; with `resize` also snaps to the preset size, keeping the top-left corner.
    private func applyLayout(resize: Bool) {
        guard let p = panel else { return }
        let target = size.frame(for: style)
        if style == .strip {
            // Setting resize increments clears the square aspect ratio. Height is fixed per size.
            p.contentResizeIncrements = NSSize(width: 1, height: 1)
            p.contentMinSize = NSSize(width: 220, height: target.height)
            p.contentMaxSize = NSSize(width: 720, height: target.height)
        } else {
            p.contentAspectRatio = NSSize(width: 1, height: 1)
            p.contentMinSize = NSSize(width: 160, height: 160)
            p.contentMaxSize = NSSize(width: 720, height: 720)
        }
        let cur = p.frame
        let wrongShape = style == .strip ? cur.height != target.height : abs(cur.width - cur.height) > 1
        guard resize || wrongShape else { return }
        let f = NSRect(x: cur.minX, y: cur.maxY - target.height, width: target.width, height: target.height)
        p.setFrame(f, display: true, animate: false)
        (p.contentView as? NSHostingView<MiniPlayerView>)?.layer?.cornerRadius = style == .strip ? 12 : 16
    }

    private func makePanel() -> NSPanel {
        let start = size.frame(for: style)
        let p = CardPanel(contentRect: NSRect(origin: .zero, size: start),
                          styleMask: [.borderless, .nonactivatingPanel, .resizable],
                          backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MiniPlayerView { [weak self] in self?.hide() })
        host.wantsLayer = true
        host.layer?.cornerRadius = style == .strip ? 12 : 16
        host.layer?.masksToBounds = true
        p.contentView = host
        if !p.setFrameUsingName("KlangMiniPlayer"), let s = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: s.maxX - start.width - 20, y: s.maxY - start.height - 20))
        }
        p.setFrameAutosaveName("KlangMiniPlayer")
        panel = p
        applyLayout(resize: false)
        // Scroll over the card = speaker volume. The panel never becomes key, but scroll
        // events still go to the window under the cursor, so a local monitor sees them.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak p] e in
            guard let self, let p, e.window === p else { return e }
            let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 12 : e.scrollingDeltaY
            self.scrollAccum += e.isDirectionInvertedFromDevice ? -d : d
            let steps = Int(self.scrollAccum)
            if steps != 0 {
                self.scrollAccum -= CGFloat(steps)
                Player.shared.setVolume(Player.shared.volume + Double(steps))
            }
            return nil
        }
        return p
    }
}

private final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct MiniPlayerView: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var card = MiniPlayer.shared
    @ObservedObject var lib = Library.shared
    let close: () -> Void
    @State private var hover = false
    @State private var dragging = false
    @State private var showVolume = false
    @State private var volumeHide: Task<Void, Never>?

    private var art: URL? { player.current?.artURL(size: 800) }

    var body: some View {
        GeometryReader { geo in
            Group {
                if card.style == .strip {
                    strip(geo.size)
                } else {
                    square(geo.size.width, minimal: card.style == .art)
                }
            }
            .overlay(alignment: .topLeading) {
                if hover {
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: card.style == .strip ? 13 : 16))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(card.style == .strip ? 4 : 8)
                }
            }
            .overlay(alignment: .topTrailing) {
                // ♥ on hover (square styles; the strip has it in the context menu).
                if hover, card.style != .strip, let t = player.current {
                    let on = lib.isFavorite(t.Id, server: t.isFavorite)
                    Button { lib.toggleFavorite(t) } label: {
                        Image(systemName: on ? "heart.fill" : "heart")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(on ? Color.pink : .white)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(9)
                    .accessibilityLabel(on ? Text("Remove from Favorites") : Text("Add to Favorites"))
                }
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onChange(of: player.volume) {
            withAnimation(.easeOut(duration: 0.15)) { showVolume = true }
            volumeHide?.cancel()
            volumeHide = Task {
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.3)) { showVolume = false }
            }
        }
        .contextMenu {
            Button(player.state == .playing ? LocalizedStringKey("Pause") : LocalizedStringKey("Play")) { player.toggle() }
            Button("Next") { player.next() }
            if let t = player.current {
                Button(Library.shared.currentIsFavorite ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Add to Favorites")) {
                    Library.shared.toggleFavorite(t)
                }
            }
            Divider()
            Picker("Card Style", selection: Binding(get: { card.style }, set: { card.setStyle($0) })) {
                ForEach(CardStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Card Size", selection: Binding(get: { card.size }, set: { card.setSize($0) })) {
                ForEach(CardSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Close Card", action: close)
        }
    }

    // MARK: Square card (cover with controls / cover only)

    private func square(_ s: CGFloat, minimal: Bool) -> some View {
        let showInfo = !minimal || hover
        return ZStack(alignment: .bottom) {
            artwork(iconSize: s * 0.25)
                .frame(width: s, height: s)
                .clipped()
                .gesture(dragGesture)

            if showInfo {
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: s * 0.5)
                    .allowsHitTesting(false)
                    .transition(.opacity)

                VStack(alignment: .leading, spacing: s * 0.025) {
                    Marquee(text: player.current?.Name ?? String(localized: "Nothing playing"),
                            font: .system(size: max(12, s * 0.055), weight: .semibold))
                    Marquee(text: player.current?.artist ?? " ", font: .system(size: max(10, s * 0.042)))
                        .foregroundStyle(.white.opacity(0.75))
                    TrackProgressLine()
                        .frame(height: 3)
                        .padding(.top, 2)
                    HStack(spacing: s * 0.08) {
                        controls(play: max(16, s * 0.085))
                    }
                    .font(.system(size: max(12, s * 0.055)))
                    .padding(.horizontal, s * 0.06)
                    .padding(.vertical, s * 0.022)
                    .glass(Capsule(), interactive: true)
                    .frame(maxWidth: .infinity)
                }
                .foregroundStyle(.white)
                .padding(s * 0.05)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .transition(.opacity)
            } else {
                // Cover only: a thin progress line at the bottom edge.
                TrackProgressLine()
                    .frame(height: 3)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(.horizontal, s * 0.06)
                    .padding(.bottom, s * 0.045)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                if hover && !minimal, let n = player.upcoming.first {
                    HStack(spacing: 4) {
                        Text("Next:").opacity(0.7)
                        Text(verbatim: "\(n.Name) — \(n.artist)").lineLimit(1)
                    }
                    .font(.system(size: max(10, s * 0.038)))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .glass(Capsule())
                    .padding(.horizontal, 34)
                }
                if showVolume { volumeBadge(width: s * 0.3, font: max(10, s * 0.04)) }
            }
            .foregroundStyle(.white)
            .padding(.top, 10)
            .allowsHitTesting(false)
        }
    }

    // MARK: Strip

    private func strip(_ size: CGSize) -> some View {
        let h = size.height
        return HStack(spacing: h * 0.16) {
            artwork(iconSize: h * 0.35)
                .frame(width: h, height: h)
                .clipped()
            VStack(alignment: .leading, spacing: h * 0.04) {
                if showVolume {
                    volumeBadge(width: max(60, size.width * 0.25), font: max(10, h * 0.16))
                } else {
                    Marquee(text: player.current?.Name ?? String(localized: "Nothing playing"),
                            font: .system(size: max(11, h * 0.19), weight: .semibold))
                    Marquee(text: player.current?.artist ?? " ", font: .system(size: max(10, h * 0.155)))
                        .foregroundStyle(.white.opacity(0.7))
                }
                TrackProgressLine()
                    .frame(height: 3)
                    .padding(.top, h * 0.04)
            }
            HStack(spacing: h * 0.18) {
                controls(play: max(14, h * 0.26))
            }
            .font(.system(size: max(11, h * 0.18)))
            .padding(.trailing, h * 0.2)
        }
        .foregroundStyle(.white)
        .frame(width: size.width, height: h)
        .background {
            ZStack {
                Color(white: 0.12)
                AsyncImage(url: art) { $0.image?.resizable().aspectRatio(contentMode: .fill) }
                    .id(art)
                    .blur(radius: 24)
                    .opacity(0.6)
                Color.black.opacity(0.35)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    // MARK: Pieces

    private func artwork(iconSize: CGFloat) -> some View {
        AsyncImage(url: art) { phase in
            if let img = phase.image {
                img.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.25), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "hifispeaker").font(.system(size: iconSize)).foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .id(art)
    }

    /// Move the panel by dragging the card.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2).onChanged { _ in
            if !dragging, let e = NSApp.currentEvent, let w = e.window {
                dragging = true
                w.performDrag(with: e)
            }
        }.onEnded { _ in dragging = false }
    }

    @ViewBuilder
    private func controls(play: CGFloat) -> some View {
        Group {
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
            Button { player.toggle() } label: {
                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: play))
                    .frame(width: play * 1.15)
            }
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .disabled(!player.hasNext)
        }
        .buttonStyle(.plain)
        .disabled(player.current == nil)
    }

    private func volumeBadge(width: CGFloat, font: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
            ProgressLine(value: player.maxVolume > 0 ? player.volume / player.maxVolume : 0)
                .frame(width: width, height: 4)
            Text("\(Int(player.volume))").monospacedDigit()
        }
        .font(.system(size: font))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glass(Capsule())
        .transition(.opacity)
    }
}

struct ProgressLine: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white.opacity(0.9)).frame(width: g.size.width * min(1, max(0, value)))
            }
        }
    }
}

/// Progress of the current track; observes only the playback clock.
struct TrackProgressLine: View {
    @ObservedObject var clock = Player.shared.clock
    var body: some View {
        let d = Player.shared.duration
        ProgressLine(value: d > 0 ? clock.position / d : 0)
    }
}
