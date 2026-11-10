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
    @State private var speakers: [Renderer] = []
    @State private var searching = false

    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var menuBar = Integrations.showInMenuBar

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group("Сервер Emby", icon: "server.rack") {
                    field("Адрес", text: $server, prompt: "http://192.168.1.10:8096")
                    if loggedIn {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(Config.userName.isEmpty ? "Подключено" : "Вход: \(Config.userName)")
                                .font(.system(size: 12))
                            Spacer()
                            Button("Выйти") {
                                Config.apiKey = ""
                                Config.userId = ""
                                loggedIn = false
                            }
                            .controlSize(.small)
                        }
                    } else {
                        field("Пользователь", text: $user, prompt: "имя в Emby")
                        HStack {
                            Text("Пароль").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                            SecureField("", text: $password).textFieldStyle(.roundedBorder).onSubmit(login)
                        }
                        HStack {
                            if let loginState { Text(loginState).font(.system(size: 11)).foregroundStyle(.red) }
                            Spacer()
                            if loggingIn { ProgressView().controlSize(.small) }
                            Button("Войти", action: login)
                                .controlSize(.small)
                                .disabled(server.isEmpty || user.isEmpty || loggingIn)
                        }
                    }
                }

                group("Колонка", icon: "hifispeaker") {
                    HStack {
                        field("IP", text: $speakerIP, prompt: "192.168.1.20")
                        Button { Task { await discover() } } label: {
                            if searching { ProgressView().controlSize(.small) } else { Text("Найти") }
                        }
                        .controlSize(.small)
                        .disabled(searching)
                    }
                    ForEach(speakers) { s in
                        HStack(spacing: 8) {
                            Image(systemName: s.ip == speakerIP ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(s.ip == speakerIP ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(s.name).font(.system(size: 12))
                                Text("\(s.manufacturer) · \(s.ip)\(s.isSupported ? "" : " · может не работать")")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            speakerIP = s.ip
                            Config.speakerName = s.name
                        }
                    }
                    Text("Поддерживаются колонки на Frontier Silicon (Loewe klang и др.): они играют AAC по сети, но не FLAC.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                group("Mac", icon: "laptopcomputer") {
                    Toggle("Запускать при входе", isOn: $loginItem)
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
                    Toggle("Название и кнопки в строке меню", isOn: $menuBar)
                        .font(.system(size: 12))
                        .onChange(of: menuBar) { Integrations.showInMenuBar = menuBar }
                    HStack {
                        Text("Кэш AAC: до 3 ГБ").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Показать") { NSWorkspace.shared.open(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("KlangPlayer")) }
                            .controlSize(.small)
                    }
                }

                HStack {
                    Spacer()
                    Button("Готово", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!loggedIn || speakerIP.isEmpty)
                }
            }
            .padding(16)
        }
        .task { if speakers.isEmpty && Config.speakerIP.isEmpty { await discover() } }
    }

    private func group<C: View>(_ title: String, icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            TextField("", text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder)
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

    private func discover() async {
        searching = true
        speakers = await Discovery.renderers()
        if speakerIP.isEmpty, let s = speakers.first(where: \.isSupported) {
            speakerIP = s.ip
            Config.speakerName = s.name
        }
        searching = false
    }

    private func save() {
        if server != Config.embyURL { Config.embyURL = server }
        if speakerIP != Config.speakerIP {
            Config.speakerIP = speakerIP
            if let s = speakers.first(where: { $0.ip == speakerIP }) { Config.speakerName = s.name }
        }
        Task { await player.refreshVolume() }
        done()
    }
}
