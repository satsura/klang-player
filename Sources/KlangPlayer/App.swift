import SwiftUI

@main
struct KlangPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var player = Player.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .task { if Library.shared.albums.isEmpty { await Library.shared.load() } }
        } label: {
            Image(systemName: player.state == .playing ? "hifispeaker.fill" : "hifispeaker")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            Task { @MainActor in await Player.shared.selfTest() }
        }
        if args.contains("--discover") {
            Task {
                for r in await Discovery.renderers() {
                    print("\(r.isSupported ? "+" : " ") \(r.ip)  \(r.name)  [\(r.manufacturer)]")
                }
                exit(0)
            }
        }
        // Debug: show the UI in a regular window (KlangPlayer --window [x y]).
        if let i = args.firstIndex(of: "--window") {
            Task { @MainActor in
                let x = args.count > i + 2 ? Double(args[i + 1]) ?? 80 : 80
                let y = args.count > i + 2 ? Double(args[i + 2]) ?? 80 : 80
                let w = NSWindow(contentViewController: NSHostingController(
                    rootView: ContentView().task { await Library.shared.load() }))
                w.styleMask = [.titled, .closable]
                w.setContentSize(NSSize(width: 400, height: 680))
                // Top-left in global coordinates of the primary display (same as `screencapture -R`).
                let top = NSScreen.screens.first.map { $0.frame.maxY } ?? 1000
                w.setFrameTopLeftPoint(NSPoint(x: x, y: top - y))
                w.title = "Klang Player"
                w.level = .floating
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.window = w
                if args.contains("--preview") {
                    await Library.shared.load()
                    if let a = Library.shared.albums.first(where: { $0.imageTag != nil }),
                       let t = try? await Library.shared.tracks(for: a) {
                        Player.shared.preview(Array(t.prefix(6)))
                    }
                }
            }
        }
    }
}
