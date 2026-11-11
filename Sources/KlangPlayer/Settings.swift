import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var player = Player.shared
    let done: () -> Void

    @State private var server = Config.embyURL
    @State private var user = Config.userName
    @State private var password = ""
    @State private var loginState: String?
    @State private var loggingIn = false
    @State private var loggedIn = !Config.apiKey.isEmpty

    @State private var speakerIP = Config.speakerIP
    @State private var speakers: [SpeakerProfile] = Config.knownSpeakers
    @State private var searching = false

    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var menuBar = Integrations.showInMenuBar
    @State private var appMode = AppMode.current
    @State private var remoteOn = Remote.enabled
    @State private var remoteURL = Remote.url
    @State private var language = Config.language
    @State private var lfmKey = LastFM.apiKey
    @State private var lfmSecret = LastFM.secret
    @State private var lfmUser = LastFM.userName
    @State private var lfmScrobble = LastFM.scrobbling
    @State private var lfmState: String?
    @State private var lfmConnecting = false
    @State private var coverState: String?
    @State private var normalize = Config.normalizeLoudness
    @State private var autoplay = Player.shared.autoplay
    @State private var coverRunning = false
    private let startLanguage = Config.language

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group("Emby Server", icon: "server.rack") {
                    field("Address", text: $server, prompt: "http://192.168.1.10:8096")
                    if loggedIn {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(Config.userName.isEmpty ? LocalizedStringKey("Connected") : LocalizedStringKey("Signed in as \(Config.userName)"))
                                .font(.system(size: 12))
                            Spacer()
                            Button("Sign Out") {
                                Config.apiKey = ""
                                Config.userId = ""
                                loggedIn = false
                            }
                            .controlSize(.small)
                        }
                    } else {
                        field("User", text: $user, prompt: "Emby user name")
                        HStack {
                            Text("Password").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                            SecureField("", text: $password).textFieldStyle(.roundedBorder).onSubmit(login)
                        }
                        HStack {
                            if let loginState { Text(loginState).font(.system(size: 11)).foregroundStyle(.red) }
                            Spacer()
                            if loggingIn { ProgressView().controlSize(.small) }
                            Button("Sign In", action: login)
                                .controlSize(.small)
                                .disabled(server.isEmpty || user.isEmpty || loggingIn)
                        }
                    }
                }

                group("Speaker", icon: "hifispeaker") {
                    HStack {
                        field("IP", text: $speakerIP, prompt: "192.168.1.20")
                        Button { Task { await discover() } } label: {
                            if searching { ProgressView().controlSize(.small) } else { Text("Find") }
                        }
                        .controlSize(.small)
                        .disabled(searching)
                    }
                    ForEach(speakers) { s in
                        HStack(spacing: 8) {
                            Image(systemName: s.ip == speakerIP ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(s.ip == speakerIP ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: s.name).font(.system(size: 12))
                                Text(verbatim: [s.manufacturer, s.ip, s.formatLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .pressable { speakerIP = s.ip }
                    }
                    Text("Speakers that accept FLAC get the original files. Others (Loewe klang and other Frontier Silicon speakers) get AAC 320.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                group("Playback", icon: "waveform") {
                    Toggle("Level loudness (EBU R128)", isOn: $normalize)
                        .font(.system(size: 12))
                        .onChange(of: normalize) { Config.normalizeLoudness = normalize }
                    Text("Brings tracks converted for the speaker to the same loudness, so albums and compilations don't jump in volume. Speakers that get original FLAC files play them as they are.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Toggle("When the queue ends, play similar music", isOn: $autoplay)
                        .font(.system(size: 12))
                        .onChange(of: autoplay) { player.setAutoplay(autoplay) }
                }

                group("Last.fm", icon: "music.note.list") {
                    if LastFM.isConnected, !lfmUser.isEmpty {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Connected as \(lfmUser)").font(.system(size: 12))
                            Spacer()
                            Button("Disconnect") { LastFM.shared.disconnect(); lfmUser = "" }.controlSize(.small)
                        }
                        Toggle("Scrobble played tracks", isOn: $lfmScrobble)
                            .font(.system(size: 12))
                            .onChange(of: lfmScrobble) { LastFM.scrobbling = lfmScrobble }
                        Text("♥ in the app also loves the track on Last.fm. If Emby's Last.fm plugin scrobbles for this user too, turn scrobbling off here to avoid doubles.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        field("API key", text: $lfmKey, prompt: "last.fm/api/account/create")
                        HStack {
                            Text("Secret").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                            SecureField("", text: $lfmSecret).textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            if let lfmState { Text(lfmState).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                            Spacer()
                            if lfmConnecting { ProgressView().controlSize(.small) }
                            Button("Connect…", action: connectLastFM)
                                .controlSize(.small)
                                .disabled(lfmKey.isEmpty || lfmSecret.isEmpty || lfmConnecting)
                        }
                        Text("Scrobbling, ♥ as love, album and artist descriptions. Create a free API account on last.fm, paste the key and secret, then allow access in the browser.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }

                group("Library", icon: "photo.on.rectangle") {
                    HStack {
                        Button("Fill Missing Album Covers") { fillCovers() }
                            .controlSize(.small)
                            .disabled(coverRunning || !loggedIn)
                        if coverRunning { ProgressView().controlSize(.small) }
                    }
                    if let coverState { Text(coverState).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                    Text("Albums without a cover in Emby get the picture embedded in their tracks, or a cover from Deezer / iTunes when artist and title match exactly. Saved to Emby; existing covers are kept. To change one: hover the cover and choose “Find another cover”.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }

                group("Phone Remote", icon: "iphone") {
                    Toggle("Control from a phone on the home network", isOn: $remoteOn)
                        .font(.system(size: 12))
                        .onChange(of: remoteOn) { Remote.enabled = remoteOn; remoteURL = Remote.url }
                    if remoteOn, let url = remoteURL {
                        HStack(alignment: .top, spacing: 12) {
                            if let qr = Remote.qrCode(url) {
                                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 96, height: 96)
                                    .padding(4).background(.white, in: RoundedRectangle(cornerRadius: 6))
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Scan with the phone camera or open the link:")
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(verbatim: url).font(.system(size: 10).monospaced()).textSelection(.enabled).lineLimit(3)
                                HStack {
                                    Button("Copy Link") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url, forType: .string)
                                    }
                                    Button("New Key") { Remote.regenerate(); remoteURL = Remote.url }
                                        .help("Old links stop working")
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }

                group("Mac", icon: "laptopcomputer") {
                    Picker("Show the player", selection: $appMode) {
                        ForEach(AppMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .font(.system(size: 12))
                    .onChange(of: appMode) { AppMode.current = appMode }
                    Text(appMode.detail)
                        .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Launch at login", isOn: $loginItem)
                        .font(.system(size: 12))
                        .onChange(of: loginItem) {
                            do {
                                if loginItem { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                loginItemError = nil
                            } catch {
                                loginItemError = error.localizedDescription
                            }
                        }
                    if let loginItemError { Text(loginItemError).font(.system(size: 10)).foregroundStyle(.red) }
                    if appMode.usesMenuBar {
                        Toggle("Track and buttons in the menu bar", isOn: $menuBar)
                            .font(.system(size: 12))
                            .onChange(of: menuBar) { Integrations.showInMenuBar = menuBar }
                    }
                    HStack {
                        Text("Language").font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $language) {
                            Text("System").tag("")
                            Text(verbatim: "English").tag("en")
                            Text(verbatim: "Русский").tag("ru")
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .onChange(of: language) { Config.language = language }
                    }
                    if language != startLanguage {
                        HStack {
                            Text("Restart to apply the language").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Restart") { relaunch() }.controlSize(.small)
                        }
                    }
                    HStack {
                        Text("AAC cache: up to 3 GB").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Show") { NSWorkspace.shared.open(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("KlangPlayer")) }
                            .controlSize(.small)
                    }
                }

                HStack {
                    Spacer()
                    Button("Done", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!loggedIn || speakerIP.isEmpty)
                }
            }
            .padding(16)
        }
        .task { if speakers.isEmpty && Config.speakerIP.isEmpty { await discover() } }
    }

    private func group<C: View>(_ title: LocalizedStringKey, icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            TextField("", text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder)
        }
    }

    private func connectLastFM() {
        LastFM.apiKey = lfmKey
        LastFM.secret = lfmSecret
        lfmConnecting = true
        lfmState = String(localized: "Allow access in the browser…")
        Task {
            do {
                lfmUser = try await LastFM.shared.connect()
                lfmState = nil
            } catch {
                lfmState = error.localizedDescription
            }
            lfmConnecting = false
        }
    }

    private func fillCovers() {
        coverRunning = true
        coverState = nil
        Task {
            let r = await Covers.fillMissing { i, n in
                coverState = String(localized: "Album \(i) of \(n)…")
            }
            await Library.shared.load()
            coverState = String(localized: "Covers added: \(r.fixed). Not found: \(r.missing).")
            coverRunning = false
        }
    }

    private func login() {
        guard !server.isEmpty, !user.isEmpty else { return }
        loggingIn = true
        loginState = nil
        Task {
            do {
                let r = try await Emby.shared.login(server: server, user: user, password: password)
                Config.embyURL = server
                Config.apiKey = r.token
                Config.userId = r.userId
                Config.userName = user
                password = ""
                loggedIn = true
            } catch {
                loginState = error.localizedDescription
            }
            loggingIn = false
        }
    }

    private func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        let url = Bundle.main.bundleURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    private func discover() async {
        searching = true
        let found = await Discovery.speakers()
        if !found.isEmpty {
            speakers = found
            Config.knownSpeakers = found
        }
        if speakerIP.isEmpty, let s = found.first(where: { $0.kind == .frontier }) ?? found.first {
            speakerIP = s.ip
        }
        searching = false
    }

    private func save() {
        if server != Config.embyURL { Config.embyURL = server }
        if speakerIP != Config.speakerIP, !speakerIP.isEmpty {
            // A speaker from the list, or a Frontier speaker typed in by IP.
            player.useSpeaker(speakers.first { $0.ip == speakerIP } ?? .frontier(ip: speakerIP))
        }
        Task { await player.refreshVolume() }
        done()
    }
}
