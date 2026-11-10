import AppKit
import SwiftUI

/// Floating cover card above all windows. A non-activating panel: it never takes focus or keyboard input.
@MainActor
final class MiniPlayer {
    static let shared = MiniPlayer()

    private var panel: NSPanel?
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

    private func makePanel() -> NSPanel {
        let p = CardPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 280),
                          styleMask: [.borderless, .nonactivatingPanel, .resizable],
                          backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentAspectRatio = NSSize(width: 1, height: 1)
        p.contentMinSize = NSSize(width: 180, height: 180)
        p.contentMaxSize = NSSize(width: 640, height: 640)
        let host = NSHostingView(rootView: MiniPlayerView { [weak self] in self?.hide() })
        host.wantsLayer = true
        host.layer?.cornerRadius = 16
        host.layer?.masksToBounds = true
        p.contentView = host
        if !p.setFrameUsingName("KlangMiniPlayer"), let s = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: s.maxX - 300, y: s.maxY - 300))
        }
        p.setFrameAutosaveName("KlangMiniPlayer")
        return p
    }
}

private final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct MiniPlayerView: View {
    @ObservedObject var player = Player.shared
    let close: () -> Void
    @State private var hover = false
    @State private var dragging = false

    private var art: URL? {
        Emby.shared.imageURL(itemId: player.current?.AlbumId, tag: player.current?.AlbumPrimaryImageTag, size: 800)
    }

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack(alignment: .bottom) {
                AsyncImage(url: art) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            LinearGradient(colors: [Color(white: 0.25), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                            Image(systemName: "hifispeaker").font(.system(size: s * 0.25)).foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }
                .frame(width: s, height: s)
                .clipped()
                .gesture(DragGesture(minimumDistance: 2).onChanged { _ in
                    // Move the panel by dragging the cover.
                    if !dragging, let e = NSApp.currentEvent, let w = e.window {
                        dragging = true
                        w.performDrag(with: e)
                    }
                }.onEnded { _ in dragging = false })

                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: s * 0.5)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: s * 0.025) {
                    Text(player.current?.Name ?? String(localized: "Nothing playing"))
                        .font(.system(size: max(12, s * 0.055), weight: .semibold))
                        .lineLimit(1)
                    Text(player.current?.artist ?? " ")
                        .font(.system(size: max(10, s * 0.042)))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    ProgressLine(value: player.duration > 0 ? player.position / player.duration : 0)
                        .frame(height: 3)
                        .padding(.top, 2)
                    HStack(spacing: s * 0.08) {
                        Spacer()
                        Button { player.previous() } label: { Image(systemName: "backward.fill") }
                        Button { player.toggle() } label: {
                            Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                                .font(.system(size: max(16, s * 0.085)))
                                .frame(width: max(20, s * 0.1))
                        }
                        Button { player.next() } label: { Image(systemName: "forward.fill") }
                            .disabled(player.upcoming.isEmpty)
                        Spacer()
                    }
                    .font(.system(size: max(12, s * 0.055)))
                    .buttonStyle(.plain)
                    .disabled(player.current == nil)
                }
                .foregroundStyle(.white)
                .padding(s * 0.05)
                .shadow(color: .black.opacity(0.5), radius: 3)
            }
            .overlay(alignment: .topLeading) {
                if hover {
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            }
        }
        .onHover { hover = $0 }
        .contextMenu {
            Button(player.state == .playing ? LocalizedStringKey("Pause") : LocalizedStringKey("Play")) { player.toggle() }
            Button("Next") { player.next() }
            Divider()
            Button("Close Card", action: close)
        }
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
