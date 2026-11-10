import SwiftUI

@main
struct KlangPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // The UI lives in the menu bar (StatusBar) and the floating card; no regular windows.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    /// klangplayer://toggle | next | prev | card — used by the widget.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for u in urls where u.scheme == "klangplayer" {
                switch u.host {
                case "toggle": Player.shared.toggle()
                case "next": Player.shared.next()
                case "prev": Player.shared.previous()
                case "card": MiniPlayer.shared.toggle()
                default: break
                }
            }
            // Give focus back to whatever was active before the widget click.
            NSApp.deactivate()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if !args.contains("--discover") {
            Task { @MainActor in
                _ = Player.shared
                StatusBar.shared.start()
                Integrations.shared.start()
                MiniPlayer.shared.restore()
                if !Config.isConfigured { StatusBar.shared.showPopover() }
            }
        }
        if args.contains("--selftest") {
            Task { @MainActor in await Player.shared.selfTest() }
        }
        // Debug: download + convert the first track of $KLANG_ALBUM, print progress, exit.
        if args.contains("--prepare") {
            Task { @MainActor in
                let want = ProcessInfo.processInfo.environment["KLANG_ALBUM"] ?? ""
                guard let a = try? await Emby.shared.albums().first(where: { $0.Name.contains(want) }),
                      let t = try? await Emby.shared.tracks(album: a.Id).first else { exit(1) }
                await Preparer.shared.setProgressHandler { _, phase in
                    FileHandle.standardError.write(Data("\(Date().timeIntervalSince1970) \(phase)\n".utf8))
                }
                let p = try? await Preparer.shared.prepare(t)
                print("done:", t.Name, t.sourceLabel, p.map { "\($0.source) \($0.mime)" } ?? "failed")
                exit(0)
            }
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
                if args.contains("--activate") {
                    w.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    w.orderFrontRegardless() // don't take keyboard focus from the user
                }
                self.window = w
            }
        }
        // Debug: fake a queue in the UI without touching the speaker (KlangPlayer --preview [--card]).
        if args.contains("--preview") {
            Speaker.dryRun = true
            Task { @MainActor in
                await Library.shared.load()
                if let a = Library.shared.albums.first(where: { $0.imageTag != nil }),
                   let t = try? await Library.shared.tracks(for: a) {
                    Player.shared.preview(Array(t.prefix(6)))
                }
                if args.contains("--card") { MiniPlayer.shared.show() }
            }
        }
    }
}
