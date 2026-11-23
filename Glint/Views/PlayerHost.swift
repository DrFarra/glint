import AVKit
import SwiftUI

/// El reproductor vive encima de las pestañas. Pasa de pantalla completa a una
/// tarjeta mini sobre la barra de pestañas con el mismo vídeo, sin cortes:
/// solo cambia el marco, así que se puede arrastrar a medias.
struct PlayerHost: View {
    @Environment(Playback.self) private var playback
    @Environment(Router.self) private var router
    /// Progreso del gesto de minimizar (0 = completo, 1 = mini) mientras el dedo está abajo.
    @State private var drag: CGFloat?
    @State private var chatOpen = true
    @State private var cardOffset: CGFloat = 0
    /// A pantalla completa, el chat va encima del vídeo en vez de en un panel al lado.
    @AppStorage("chatOverlay") private var chatOverlay = false
    @AppStorage("chatOverlayTrailing") private var overlayTrailing = false
    @AppStorage("chatOverlayOpacity") private var overlayOpacity = 1.0

    private var progress: CGFloat { drag ?? (playback.minimized ? 1 : 0) }

    var body: some View {
        if playback.media != nil {
            GeometryReader { geo in
                let layout = PlayerLayout(size: geo.size, insets: geo.safeAreaInsets, progress: progress,
                                          chatOpen: chatBeside, offset: cardOffset)
                content(layout)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .statusBarHidden(layout.landscape && progress == 0)
                    .persistentSystemOverlays(layout.landscape && progress == 0 ? .hidden : .automatic)
            }
            // Al cambiar de modo se ve el chat, si no el ajuste parece no hacer nada
            .onChange(of: chatOverlay) { withAnimation(.snappy) { chatOpen = true } }
            // A pantalla completa el teclado empuja el chat hacia arriba para ver lo que escribes;
            // en mini, la tarjeta no se mueve
            .ignoresSafeArea(playback.minimized || drag != nil ? .keyboard : [])
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .sheet(item: Binding(get: { playback.clipEditor.map(ClipEditor.init) }, set: { playback.clipEditor = $0?.url })) { editor in
                TwitchWebSheet(title: "Tu clip", url: editor.url, hint: "Ponle título y publícalo. Lo verás en los clips del canal.")
            }
            .alert("No se pudo crear el clip", isPresented: Binding(get: { playback.clipProblem != nil },
                                                                      set: { if !$0 { playback.clipProblem = nil } })) {
                Button("Vale", role: .cancel) {}
            } message: {
                Text(playback.clipProblem ?? "")
            }
        }
    }

    private struct ClipEditor: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private var viewers: Int? {
        if case .live = playback.media { playback.channel?.stream?.viewersCount } else { nil }
    }

    /// Directos y VOD tienen chat; los clips no.
    private var hasChat: Bool {
        switch playback.media {
        case .live, .video: true
        default: false
        }
    }

    /// Chat en el panel lateral (solo cuenta en horizontal; en vertical va debajo del vídeo).
    private var chatBeside: Bool { chatOpen && hasChat && !chatOverlay }

    @ViewBuilder
    private func content(_ layout: PlayerLayout) -> some View {
        let full = layout.progress < 0.01 && drag == nil

        ZStack(alignment: .topLeading) {
            Color.black
                .ignoresSafeArea()
                .opacity(1 - layout.progress)
                .allowsHitTesting(full)

            if !layout.landscape {
                PlayerDetails(onOpenChannel: openChannel)
                    .frame(width: layout.size.width, height: max(0, layout.size.height - layout.full.maxY))
                    .offset(y: layout.full.maxY + layout.progress * 240)
                    .opacity(1 - layout.progress * 2.5)
                    .allowsHitTesting(full)
            } else if chatBeside {
                ChatView(chat: playback.chat)
                    .padding(.trailing, layout.insets.trailing)
                    .frame(width: PlayerLayout.chatWidth + layout.insets.trailing,
                           height: layout.size.height + layout.insets.top + layout.insets.bottom)
                    .background(Color(white: 0.06))
                    // Deslizar el chat hacia el borde derecho lo cierra
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20).onEnded { g in
                            let dx = g.translation.width
                            if dx > abs(g.translation.height) * 1.5, dx > 70 || g.predictedEndTranslation.width > 180 {
                                withAnimation(.snappy) { chatOpen = false }
                            }
                        }
                    )
                    .offset(x: layout.size.width - PlayerLayout.chatWidth, y: -layout.insets.top)
                    .opacity(1 - layout.progress * 2.5)
                    .allowsHitTesting(full)
            }

            // Su cristal no respeta la opacidad 0: a pantalla completa no se dibuja
            if layout.progress > 0 {
                miniCard(layout)
            }

            VideoSurface(engine: playback.engine)
                .frame(width: layout.video.width, height: layout.video.height)
                .clipShape(RoundedRectangle(cornerRadius: 10 * layout.progress, style: .continuous))
                .offset(x: layout.video.minX, y: layout.video.minY)
                .allowsHitTesting(false)

            if layout.landscape, chatOverlay, chatOpen, hasChat {
                let width = min(330, layout.size.width * 0.4)
                OverlayChat(chat: playback.chat)
                    // Abajo, en el lado elegido, por encima de la barra de progreso
                    .frame(width: width, height: layout.size.height * 0.6)
                    .offset(x: overlayTrailing
                                ? layout.size.width + layout.insets.trailing - max(layout.insets.trailing, 16) - width
                                : max(layout.insets.leading, 16) - layout.insets.leading,
                            y: layout.size.height * 0.4 - max(layout.insets.bottom, 6) - 44)
                    .opacity(overlayOpacity * (1 - layout.progress * 2.5))
                    .transition(.opacity)
            }

            PlayerControls(
                engine: playback.engine,
                title: title,
                subtitle: subtitle,
                viewers: viewers,
                problem: playback.problem,
                landscape: layout.landscape,
                safe: layout.insets,
                active: layout.progress < 0.01,
                chatOpen: chatOpen && hasChat,
                chatBeside: chatBeside,
                showsChatToggle: hasChat,
                onMinimize: { withAnimation(.snappy) { playback.minimized = true } },
                onFullscreen: { Orientation.set(landscape: !layout.landscape) },
                onToggleChat: { withAnimation(.snappy) { chatOpen.toggle() } },
                onRetry: { playback.retry() },
                onDrag: { dy in
                    guard !layout.landscape else { return }
                    drag = min(1, max(0, dy / (layout.size.height * 0.55)))
                },
                onDragEnd: { dy, predicted in
                    if layout.landscape {
                        if dy > 60 { Orientation.set(landscape: false) }
                    } else if dy < -60, drag ?? 0 < 0.05 {
                        drag = nil
                        Orientation.set(landscape: true)
                    } else {
                        let minimize = predicted > layout.size.height * 0.3 || (drag ?? 0) > 0.45
                        withAnimation(.snappy) {
                            playback.minimized = minimize
                            drag = nil
                        }
                    }
                },
                // Clips solo del directo y con tu cuenta, como en la app de Twitch
                onClip: playback.channel?.stream != nil && Account.shared.token != nil
                    ? { Task { await playback.createClip() } } : nil
            )
            .frame(width: layout.video.width, height: layout.video.height)
            .offset(x: layout.video.minX, y: layout.video.minY)
            .allowsHitTesting(layout.progress < 0.99 || drag != nil)
        }
    }

    // MARK: - Tarjeta mini

    private func miniCard(_ layout: PlayerLayout) -> some View {
        let engine = playback.engine
        return HStack(spacing: 10) {
            Color.clear.frame(width: layout.miniVideoWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { engine.togglePlay() } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 44)
            }
            .accessibilityLabel(engine.isPlaying ? "Pausa" : "Reproducir")
            Button { playback.close() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 36, height: 44)
            }
            .accessibilityLabel("Cerrar")
        }
        .buttonStyle(.plain)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(width: layout.card.width, height: layout.card.height)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { withAnimation(.snappy) { playback.minimized = false } }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { cardOffset = $0.translation.width }
                .onEnded { g in
                    if abs(g.predictedEndTranslation.width) > 140 {
                        withAnimation(.snappy) { cardOffset = g.translation.width > 0 ? 500 : -500 }
                        playback.close()
                        cardOffset = 0
                    } else {
                        withAnimation(.snappy) { cardOffset = 0 }
                    }
                }
        )
        .offset(x: layout.card.minX + cardOffset, y: layout.card.minY)
        .opacity(max(0, layout.progress * 2 - 1))
        .allowsHitTesting(layout.progress > 0.99)
    }

    // MARK: - Textos

    private var title: String {
        playback.channel?.stream?.title ?? playback.video?.title ?? playback.clip?.title ?? ""
    }

    private var subtitle: String {
        playback.channel?.name ?? playback.video?.owner?.name ?? playback.clip?.broadcaster?.name ?? ""
    }

    private func openChannel() {
        guard let login = playback.login else { return }
        Orientation.set(landscape: false)
        withAnimation(.snappy) { playback.minimized = true }
        router.open(.channel(login))
    }
}

/// Marcos del vídeo a pantalla completa, de la tarjeta mini y el intermedio según el progreso.
struct PlayerLayout {
    static let chatWidth: CGFloat = 340

    let size: CGSize
    let insets: EdgeInsets
    let progress: CGFloat
    let landscape: Bool
    let full: CGRect
    let card: CGRect
    let video: CGRect
    var miniVideoWidth: CGFloat { (52 * 16 / 9).rounded() }

    init(size: CGSize, insets: EdgeInsets, progress: CGFloat, chatOpen: Bool, offset: CGFloat) {
        self.size = size
        self.insets = insets
        self.progress = progress
        landscape = size.width > size.height

        if landscape {
            let right = chatOpen ? size.width - Self.chatWidth : size.width + insets.trailing
            full = CGRect(x: -insets.leading, y: -insets.top,
                          width: right + insets.leading, height: size.height + insets.top + insets.bottom)
        } else {
            full = CGRect(x: 0, y: 0, width: size.width, height: (size.width * 9 / 16).rounded())
        }

        let cardWidth = landscape ? min(380, size.width - 24) : size.width - 16
        card = CGRect(x: size.width - cardWidth - 8, y: size.height - 64 - (landscape ? 8 : 60),
                      width: cardWidth, height: 64)
        let mini = CGRect(x: card.minX + 6 + offset, y: card.minY + 6, width: (52 * 16 / 9).rounded(), height: 52)

        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        video = CGRect(x: mix(full.minX, mini.minX), y: mix(full.minY, mini.minY),
                       width: mix(full.width, mini.width), height: mix(full.height, mini.height))
    }
}

/// Información del directo o vídeo debajo de la imagen, y el chat.
struct PlayerDetails: View {
    let onOpenChannel: () -> Void
    @Environment(Playback.self) private var playback
    @State private var expanded = false
    @State private var showVideos = false

    var body: some View {
        VStack(spacing: 0) {
            info
            Divider().overlay(Color.white.opacity(0.06))
            switch playback.media {
            case .live:
                ChatView(chat: playback.chat)
            case .video:
                Picker("Mostrar", selection: $showVideos) {
                    Text("Chat").tag(false)
                    Text("Más vídeos").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                if showVideos {
                    moreVideos
                } else {
                    ChatView(chat: playback.chat)
                }
            case .clip:
                clipPanel
            case nil:
                Spacer()
            }
        }
        .background(Color.black)
    }

    private var moreVideos: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !playback.moreVideos.isEmpty {
                    SectionHeader("Más de \(owner?.name ?? "este canal")")
                }
                ForEach(playback.moreVideos) { VideoRow(video: $0) }
            }
            .padding(16)
        }
    }

    /// Desde un clip se puede saltar a la emisión completa, justo en ese momento.
    @ViewBuilder
    private var clipPanel: some View {
        VStack(spacing: 16) {
            if let clip = playback.clip, let videoID = clip.video?.id {
                Button {
                    playback.play(.video(videoID), at: Double(clip.videoOffsetSeconds ?? 0))
                } label: {
                    Label("Ver en la emisión completa", systemImage: "play.rectangle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(.glint)
            }
            Spacer()
        }
        .padding(16)
    }

    /// Dueño del vídeo o clip (en directo se usa el canal).
    private var owner: Twitch.Broadcaster? {
        playback.video?.owner ?? playback.clip?.broadcaster
    }

    @ViewBuilder
    private var info: some View {
        let channel = playback.channel
        let video = playback.video
        let owner = self.owner
        let ref = channel?.ref ?? owner.map { ChannelRef(login: $0.login, displayName: $0.name, avatar: $0.profileImageURL) }

        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpenChannel) {
                Avatar(url: channel?.profileImageURL ?? owner?.profileImageURL, size: 40, live: channel?.stream != nil)
            }
            .buttonStyle(PressStyle())

            VStack(alignment: .leading, spacing: 3) {
                Button(action: onOpenChannel) {
                    Text(ref?.displayName ?? " ").font(.subheadline.weight(.bold))
                }
                .buttonStyle(.plain)
                Text(channel?.stream?.title ?? video?.title ?? playback.clip?.title ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? 6 : 1)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                if !playback.liveDrops.isEmpty {
                    // Como en la app de Twitch: aquí ver el directo suma para esos drops
                    Label("Drops: \(playback.liveDrops.joined(separator: ", "))", systemImage: "gift.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.glint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }

            if let link = shareURL {
                ShareLink(item: link) {
                    Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold)).frame(width: 34, height: 34)
                }
                .accessibilityLabel("Compartir")
            }
            if let ref {
                FollowButton(channel: ref, compact: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Enlace de lo que se está viendo, para compartir.
    private var shareURL: URL? {
        switch playback.media {
        case .live(let login): URL(string: "https://www.twitch.tv/\(login)")
        case .video(let id): URL(string: "https://www.twitch.tv/videos/\(id)")
        case .clip(let slug): URL(string: "https://clips.twitch.tv/\(slug)")
        case nil: nil
        }
    }

    private var meta: String {
        if let stream = playback.channel?.stream {
            // Cuánto lleva en directo, como en la app de Twitch
            let uptime = stream.createdAt.map { start -> String in
                let minutes = max(0, Int(-start.timeIntervalSinceNow / 60))
                return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
            }
            // El juego al final: es lo que se corta si no cabe
            return [stream.viewersCount.map { "\(Format.count($0)) espectadores" }, uptime, stream.game?.title]
                .compactMap { $0 }.joined(separator: " · ")
        }
        if let video = playback.video {
            return [video.game?.title, Format.ago(video.createdAt), video.viewCount.map { "\(Format.count($0)) vistas" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if let clip = playback.clip {
            return [clip.curator.map { "Clip de \($0.name)" }, clip.viewCount.map { "\(Format.count($0)) vistas" }, Format.ago(clip.createdAt)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return ""
    }
}

struct VideoSurface: UIViewRepresentable {
    let engine: PlayerEngine

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .black
        engine.attach(view.playerLayer)
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {}

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(Color.glint)
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

enum Orientation {
    static func set(landscape: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait), errorHandler: nil)
    }
}
