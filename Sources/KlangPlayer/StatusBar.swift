import AppKit
import Combine
import SwiftUI

/// The app's single menu bar item: speaker icon + current track + ⏮ ⏯ ⏭.
/// Clicking the icon/title opens the main window (a popover); right click shows a menu.
@MainActor
final class StatusBar: NSObject, NSPopoverDelegate {
    static let shared = StatusBar()

    private var item: NSStatusItem?
    private var host: NSHostingView<StatusBarView>?
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "KlangPlayerMain"
        self.item = item
        guard let button = item.button else { return }

        let host = NSHostingView(rootView: StatusBarView())
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

    /// Fits the item width to the SwiftUI content.
    func resize() {
        guard let host else { return }
        host.invalidateIntrinsicContentSize()
        item?.length = max(24, host.fittingSize.width)
    }

    func togglePopover() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func showPopover() { if !popover.isShown { togglePopover() } }
}

struct StatusBarView: View {
    @ObservedObject var player = Player.shared
    @AppStorage("showInMenuBar") private var showTrack = true

    private var title: String? {
        guard showTrack, let t = player.current else { return nil }
        return [t.artist, t.Name].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    /// Longer titles scroll inside this width.
    private static let maxTitleWidth: CGFloat = 240
    private func width(of s: String) -> CGFloat {
        let w = (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        return min(ceil(w) + 1, Self.maxTitleWidth)
    }

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: player.state == .playing ? "hifispeaker.fill" : "hifispeaker")
                    .font(.system(size: 13))
                if let title {
                    Marquee(text: title, font: .system(size: 12), active: player.state == .playing)
                        .frame(width: width(of: title))
                        .opacity(player.state == .playing ? 1 : 0.6)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { StatusBar.shared.togglePopover() }

            if title != nil {
                Group {
                    Button { player.previous() } label: { Image(systemName: "backward.fill") }
                    Button { player.toggle() } label: {
                        Image(systemName: player.state == .playing || player.state == .preparing ? "pause.fill" : "play.fill")
                    }
                    Button { player.next() } label: { Image(systemName: "forward.fill") }
                        .opacity(player.upcoming.isEmpty ? 0.35 : 1)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 20)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
        }
        .padding(.trailing, title != nil ? 4 : 0)
        .fixedSize(horizontal: true, vertical: false)
        .contextMenu {
            Button("Open Klang Player") { StatusBar.shared.showPopover() }
            Button(MiniPlayer.shared.isVisible ? LocalizedStringKey("Close Card") : LocalizedStringKey("Show card")) { MiniPlayer.shared.toggle() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}
