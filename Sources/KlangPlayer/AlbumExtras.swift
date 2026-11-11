import SwiftUI

/// Small marks on a cover: hi-res, lyrics, favorite.
struct CoverBadges: View {
    var hiRes = false
    /// Tracks with lyrics / tracks checked so far; nil = unknown.
    var lyrics: (found: Int, of: Int)? = nil
    var favorite = false

    var body: some View {
        HStack(spacing: 3) {
            if hiRes { badge(Text("Hi-Res")) }
            if let l = lyrics, l.found > 0 {
                badge(HStack(spacing: 2) {
                    Image(systemName: "quote.bubble.fill")
                    if l.of > 1 { Text(verbatim: "\(l.found)/\(l.of)") }
                })
                .tip(Text("Lyrics: \(l.found) of \(l.of) tracks"))
            }
            if favorite { badge(Image(systemName: "heart.fill").foregroundStyle(.pink)) }
        }
        .font(.system(size: 10, weight: .bold))
        .padding(4)
    }

    private func badge(_ content: some View) -> some View {
        content
            .padding(.horizontal, 4).padding(.vertical, 2)
            .foregroundStyle(.white)
            .glass(Capsule(), overImage: true)
    }
}

/// Grid of covers found in Deezer / iTunes; the chosen one is saved to Emby.
struct CoverPicker: View {
    let album: Album
    let artist: String
    let done: (Bool) -> Void
    @State private var candidates: [Covers.Candidate] = []
    @State private var loading = true
    @State private var saving: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Choose a cover").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel") { done(false) }.controlSize(.small)
            }
            Text("Saved to Emby: every Emby app will show it.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(30)
            } else if candidates.isEmpty {
                Text("Nothing found in Deezer and iTunes").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                    ForEach(candidates) { c in
                        Button { save(c) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                ZStack {
                                    Cover(url: c.thumb, size: 104, radius: 6)
                                    if saving == c.id { ProgressView().controlSize(.small) }
                                }
                                Text(verbatim: c.title).font(.system(size: 10)).lineLimit(2)
                                Text(verbatim: c.source).font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            .frame(width: 104)
                        }
                        .buttonStyle(.plain)
                        .disabled(saving != nil)
                    }
                }
            }
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(.red) }
        }
        .padding(14)
        .task {
            candidates = await Covers.search(artist: artist, album: album.Name)
            loading = false
        }
    }

    private func save(_ c: Covers.Candidate) {
        saving = c.id
        error = nil
        Task {
            do {
                try await Covers.apply(c, to: album)
                await Library.shared.load()
                done(true)
            } catch {
                self.error = error.localizedDescription
                saving = nil
            }
        }
    }
}

/// Description from Emby or Last.fm, with tags and a link.
struct AboutSection: View {
    enum Subject: Equatable { case album(artist: String, name: String), artist(String) }
    let subject: Subject
    @State private var info: LastFM.Info?
    @State private var embyText: String?
    @State private var expanded = false

    private var text: String? { embyText ?? info?.summary }

    var body: some View {
        Group {
            if let text {
                VStack(alignment: .leading, spacing: 6) {
                    Text(text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Button(expanded ? LocalizedStringKey("Less") : LocalizedStringKey("More")) { expanded.toggle() }
                            .buttonStyle(.link).font(.system(size: 10.5))
                        ForEach(info?.tags ?? [], id: \.self) { tag in
                            Text(verbatim: tag).font(.system(size: 10)).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .overlay(Capsule().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.7))
                        }
                        Spacer()
                        if embyText == nil, let url = info?.url {
                            Link("Last.fm", destination: url).font(.system(size: 10))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .task(id: subject) {
            switch subject {
            case .album(let artist, let name):
                info = await LastFM.shared.albumInfo(artist: artist, album: name)
            case .artist(let name):
                embyText = await Emby.shared.artistOverview(name)
                if embyText == nil { info = await LastFM.shared.artistInfo(name) }
            }
        }
    }
}
