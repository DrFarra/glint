import SwiftUI

struct ChannelView: View {
    let login: String
    @Environment(Playback.self) private var playback
    @State private var channel: Twitch.Channel?
    @State private var failure: String?
    @State private var showFullBio = false
    @State private var clips: [Twitch.Clip] = []
    @State private var panels: [Twitch.Panel] = []
    @State private var schedule: [Twitch.ScheduleSegment] = []
    @Environment(\.openURL) private var openURL
    @Environment(Account.self) private var account
    @State private var showSubscribe = false

    var body: some View {
        ScrollView {
            if let channel {
                content(channel)
            } else if let failure {
                ErrorState(message: failure) { await load() }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
            }
        }
        .navigationTitle(channel?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url = URL(string: "https://www.twitch.tv/\(login)") {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Compartir canal")
                }
            }
        }
        .refreshable { await load() }
        .task { if channel == nil { await load() } }
    }

    private func content(_ channel: Twitch.Channel) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            header(channel)

            if let stream = channel.stream {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader("En directo")
                    StreamCard(stream: stream.withBroadcaster(channel))
                }
                .padding(.horizontal, 16)
            }

            if !clips.isEmpty {
                ClipsRow(title: "Clips del mes", clips: clips)
                    .padding(.horizontal, 16)
            }

            if !schedule.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Próximas emisiones")
                    ForEach(schedule) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(segment.startAt?.formatted(.dateTime.weekday(.abbreviated).day().hour().minute()) ?? "")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .frame(width: 110, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(segment.title?.isEmpty == false ? segment.title! : "Directo").font(.subheadline).lineLimit(2)
                                if let game = segment.categories?.first?.displayName {
                                    Text(game).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            let videos = channel.videos?.nodes ?? []
            if !videos.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader("Emisiones anteriores")
                    ForEach(videos) { VideoRow(video: $0) }
                }
                .padding(.horizontal, 16)
            }

            if !panels.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader("Acerca de")
                    ForEach(panels) { panelView($0) }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 24)
    }

    private func header(_ channel: Twitch.Channel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Color.surface
                .frame(height: 120)
                .overlay {
                    if channel.bannerImageURL != nil { RemoteImage(url: channel.bannerImageURL) }
                }
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    Avatar(url: channel.profileImageURL, size: 76, live: channel.stream != nil)
                        .background(Circle().fill(.black).padding(-3))
                        .padding(.leading, 16)
                        .offset(y: 38)
                }
                .padding(.bottom, 30)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name).font(.title2.bold())
                    if let followers = channel.followers?.totalCount {
                        Text("\(Format.count(followers)) seguidores").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // Suscribirse o regalar subs: el pago lo hace la web de Twitch, como en su navegador
                if account.isLoggedIn {
                    Button { showSubscribe = true } label: {
                        Image(systemName: "star").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Suscribirse")
                }
                FollowButton(channel: channel.ref)
            }
            .sheet(isPresented: $showSubscribe) {
                if let url = URL(string: "https://www.twitch.tv/subs/\(channel.login)") {
                    TwitchWebSheet(title: "Suscribirse", url: url, hint: "Suscripción, regalos de subs y pago, en la web de Twitch.")
                }
            }
            .padding(.horizontal, 16)

            if let bio = channel.description, !bio.isEmpty {
                Text(bio)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(showFullBio ? nil : 2)
                    .padding(.horizontal, 16)
                    .onTapGesture { withAnimation(.snappy) { showFullBio.toggle() } }
            }
        }
    }

    /// Un panel de "Acerca de", como en la web de Twitch: imagen (que lleva al enlace), título y texto.
    private func panelView(_ panel: Twitch.Panel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = panel.imageURL {
                AsyncImage(url: URL(string: image)) { $0.resizable().scaledToFit() } placeholder: {
                    Color.surface.frame(height: 80)
                }
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture { if let link = panel.linkURL.flatMap(URL.init(string:)) { openURL(link) } }
            }
            if let title = panel.title, !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            if let text = panel.description, !text.isEmpty {
                // Twitch los escribe en Markdown: así salen los enlaces y las negritas
                Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        do {
            async let clipList = try? Twitch.clips(channel: login)
            async let about = Twitch.channelAbout(login)
            channel = try await Twitch.channel(login, withVideos: true)
            clips = await clipList ?? []
            (panels, schedule) = await about
            failure = channel == nil ? "Este canal no existe" : nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

extension Twitch.Stream {
    /// La consulta de canal no repite el emisor dentro del directo.
    func withBroadcaster(_ channel: Twitch.Channel) -> Twitch.Stream {
        guard broadcaster == nil else { return self }
        return Twitch.Stream(id: id, title: title, viewersCount: viewersCount, createdAt: createdAt,
                             previewImageURL: previewImageURL, game: game,
                             broadcaster: Twitch.Broadcaster(login: channel.login, displayName: channel.displayName,
                                                             profileImageURL: channel.profileImageURL, userID: channel.userID),
                             archiveVideo: archiveVideo)
    }
}
