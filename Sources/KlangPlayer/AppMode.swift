import AppKit
import SwiftUI

/// How the app shows itself: a player window with a Dock icon, the menu bar, or both.
enum AppMode: String, CaseIterable, Identifiable {
    case both, window, menuBar
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .both: "Window and menu bar"
        case .window: "Window only"
        case .menuBar: "Menu bar only"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .both: "A player window with a Dock icon, and the track with buttons in the menu bar. The window can be hidden to the menu bar."
        case .window: "A regular app: the window and the Dock icon, nothing in the menu bar."
        case .menuBar: "Only in the menu bar. The window opens on demand; the Dock icon shows while it's open."
        }
    }

    var usesMenuBar: Bool { self != .window }
    var usesDock: Bool { self != .menuBar }

    static var current: AppMode {
        get { AppMode(rawValue: UserDefaults.standard.string(forKey: "appMode") ?? "") ?? .both }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "appMode")
            MainActor.assumeIsolated { Presence.apply() }
        }
    }
}

/// Dock icon, menu bar items and the player window, according to `AppMode`.
@MainActor
enum Presence {
    /// The window was hidden to the menu bar: no Dock icon until it's opened again.
    static var hiddenToMenuBar = false

    static func launch(atLogin: Bool) {
        let mode = AppMode.current
        // Started at login: stay quiet (menu bar or Dock), don't put a window on the screen.
        if atLogin, mode.usesMenuBar { hiddenToMenuBar = true }
        apply(showWindowIfNothingElse: !atLogin)
        if !atLogin, mode.usesDock { LibraryWindow.shared.show() }
        if !Config.isConfigured { showSettings() }
    }

    static func apply(showWindowIfNothingElse: Bool = true) {
        let mode = AppMode.current
        if mode.usesMenuBar { StatusBar.shared.start() } else { StatusBar.shared.stop() }
        if !mode.usesMenuBar { hiddenToMenuBar = false }
        updateDock()
        // Without the menu bar the window is the only way into the app.
        if showWindowIfNothingElse, !mode.usesMenuBar, !LibraryWindow.shared.isVisible { LibraryWindow.shared.show() }
    }

    static func updateDock() {
        let dock = LibraryWindow.shared.isVisible || (AppMode.current.usesDock && !hiddenToMenuBar)
        let policy: NSApplication.ActivationPolicy = dock ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    static func showWindow() {
        hiddenToMenuBar = false
        LibraryWindow.shared.show()
    }

    /// Closes the window and removes the Dock icon; the menu bar stays.
    static func hideToMenuBar() {
        guard AppMode.current.usesMenuBar else { return }
        hiddenToMenuBar = true
        LibraryWindow.shared.close()
        updateDock()
    }

    static func showSettings() {
        if AppMode.current == .menuBar, !LibraryWindow.shared.isVisible {
            StatusBar.shared.showPopover()      // opens on its settings while not configured
        } else {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    /// Right click on the Dock icon.
    static func dockMenu() -> NSMenu {
        let p = Player.shared
        let menu = NSMenu()
        if let t = p.current {
            let item = NSMenuItem(title: [t.artist, t.Name].filter { !$0.isEmpty }.joined(separator: " — "), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(MenuAction(title: p.state == .playing ? String(localized: "Pause") : String(localized: "Play")) { p.toggle() })
            if p.hasNext { menu.addItem(MenuAction(title: String(localized: "Next")) { p.next() }) }
            menu.addItem(MenuAction(title: String(localized: "Previous")) { p.previous() })
            let on = Library.shared.currentIsFavorite
            menu.addItem(MenuAction(title: on ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")) {
                Library.shared.toggleFavorite(t)
            })
            menu.addItem(.separator())
        }
        menu.addItem(MenuAction(title: MiniPlayer.shared.isVisible ? String(localized: "Close Card") : String(localized: "Show card")) {
            MiniPlayer.shared.toggle()
        })
        if AppMode.current.usesMenuBar, LibraryWindow.shared.isVisible {
            menu.addItem(MenuAction(title: String(localized: "Hide to Menu Bar")) { hideToMenuBar() })
        }
        return menu
    }
}

/// App menu: Controls, and the player window in the Window menu.
struct PlayerCommands: Commands {
    @AppStorage("appMode") private var mode = AppMode.both.rawValue

    var body: some Commands {
        CommandMenu("Controls") {
            Button("Play/Pause") { MainActor.assumeIsolated { Player.shared.toggle() } }
            Button("Next") { MainActor.assumeIsolated { Player.shared.next() } }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous") { MainActor.assumeIsolated { Player.shared.previous() } }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Divider()
            Button("Volume Up") { MainActor.assumeIsolated { Player.shared.setVolume(Player.shared.volume + 1) } }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { MainActor.assumeIsolated { Player.shared.setVolume(Player.shared.volume - 1) } }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Button("Floating card") { MainActor.assumeIsolated { MiniPlayer.shared.toggle() } }
        }
        CommandGroup(before: .windowList) {
            Button("Player Window") { MainActor.assumeIsolated { Presence.showWindow() } }
                .keyboardShortcut("0", modifiers: .command)
            if AppMode(rawValue: mode)?.usesMenuBar ?? true {
                Button("Hide to Menu Bar") { MainActor.assumeIsolated { Presence.hideToMenuBar() } }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
            Divider()
        }
    }
}
