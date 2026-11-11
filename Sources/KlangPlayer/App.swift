import SwiftUI

@main
struct KlangPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // The UI lives in the menu bar (StatusBar) and the floating card. ⌘, and the app menu
    // open this window, so it shows the same settings as the popover.
    var body: some Scene {
        Settings {
            SettingsView {
                NSApp.keyWindow?.close()
                Task { await Library.shared.load() }
            }
            .frame(width: 420, height: 640)
        }
        .commands { PlayerCommands() }
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

    /// Click on the Dock icon with the window closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { if !LibraryWindow.shared.isVisible { Presence.showWindow() } }
        return true
    }

    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { Presence.dockMenu() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        // Started by "Launch at login"?
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = launchEvent?.eventID == kAEOpenApplication
            && launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        // Debug runs share the app's settings: keep them from saving over the user's queue.
        let debugFlags: Set = ["--selftest", "--fill-covers", "--discover", "--relocate", "--prepare", "--preview"]
        if args.contains(where: debugFlags.contains) {
            MainActor.assumeIsolated { Player.persistQueue = false }
        }
        // SwiftUI may open the Settings scene on launch (e.g. when started from a terminal); it's only for ⌘,.
        DispatchQueue.main.async {
            for w in NSApp.windows where w.identifier?.rawValue.contains("Settings") == true { w.close() }
        }
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        // Same as Settings → Library → Album Covers from Track Files, without UI.
        if args.contains("--fill-covers") {
            Task { @MainActor in
                await Library.shared.load()
                let r = await Covers.fillMissing { i, n in print("album \(i)/\(n)") }
                print("covers added: \(r.fixed), no picture in files: \(r.missing)")
                exit(0)
            }
            return
        }
        // Headless debug runs: no menu bar, no restoring the queue, never touch the speaker.
        let headless = ["--discover", "--relocate", "--prepare", "--fill-covers"].contains(where: args.contains)
        if !headless {
            Task { @MainActor in
                if !args.contains("--selftest") && !args.contains("--preview") {
                    Player.shared.restoreQueue()
                    Task { await Player.shared.adoptSpeaker() }
                }
                if args.contains("--selftest") || args.contains("--preview") {
                    StatusBar.shared.start()     // debug copies: no window, no Dock icon
                } else {
                    Presence.launch(atLogin: atLogin)
                }
                NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { Player.shared.saveQueue() }
                }
                // Refresh the speaker list and the current speaker's address in the background.
                if !args.contains("--selftest") && !args.contains("--preview") {
                    Task { await Player.relocateSpeaker() }
                }
                Integrations.shared.start()
                MiniPlayer.shared.restore()
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
        // Debug: run speaker relocation once and print the result.
        if args.contains("--relocate") {
            Task { @MainActor in
                let t0 = Date()
                let moved = await Player.relocateSpeaker()
                let sp = Config.speaker
                print("moved=\(moved) speaker=\(sp?.name ?? "-")@\(sp?.ip ?? "-") udn=\(sp?.udn ?? "-") in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
                exit(0)
            }
        }
        if args.contains("--discover") {
            Task {
                for p in await Discovery.speakers() {
                    print("\(p.kind.rawValue)\t\(p.ip)\t\(p.name) [\(p.manufacturer)] udn=\(p.udn)\n\tav=\(p.avControl) rc=\(p.rcControl ?? "-")\n\t\(p.formatLabel)  sinks: \(p.sinks.joined(separator: " "))")
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
        // Debug: the large window without taking focus (with --preview: no speaker).
        if args.contains("--library") {
            Task { @MainActor in LibraryWindow.shared.show(activate: false) }
        }
        // Debug: fake a queue in the UI without touching the speaker (KlangPlayer --preview [--card]).
        if args.contains("--preview") {
            Speaker.dryRun = true
            Task { @MainActor in
                await Library.shared.load()
                let want = ProcessInfo.processInfo.environment["KLANG_ALBUM"] ?? ""
                if let a = Library.shared.albums.first(where: { want.isEmpty ? $0.imageTag != nil : $0.Name.contains(want) }),
                   let t = try? await Library.shared.tracks(for: a) {
                    Player.shared.preview(Array(t.prefix(6)))
                }
                if args.contains("--card") { MiniPlayer.shared.show() }
            }
        }
    }
}
