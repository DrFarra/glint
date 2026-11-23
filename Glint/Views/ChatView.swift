import SwiftUI

/// Chat en vivo. Sigue al último mensaje; si subes para leer, se pausa y avisa
/// de cuántos mensajes nuevos hay en vez de arrastrarte hacia abajo.
///
/// La lista va dada la vuelta (lo más nuevo arriba, y luego se voltea la vista
/// entera): así cada mensaje nuevo entra en la posición 0 y el scroll no tiene que
/// recolocarse, que era lo que hacía vibrar el chat al cabo de un rato.
struct ChatView: View {
    let chat: ChatClient
    @State private var position = ScrollPosition(edge: .top)
    @State private var phase: ScrollPhase = .idle
    @State private var atNewest = true
    @State private var replyTo: ChatMessage?
    @AppStorage("chatTextSize") private var textSize = ChatTextSize.normal
    @AppStorage("chatAnimation") private var animate = true
    @AppStorage("chatTimestamps") private var timestamps = false
    @Environment(Playback.self) private var playback
    /// Ficha del usuario que se está mirando (su login).
    @State private var profile: String?
    @State private var showPrediction = false
    @State private var showPoll = false
    /// Mensaje fijado: desplegado entero, u ocultado (hasta que fijen otro distinto).
    @State private var pinnedExpanded = false
    @State private var hiddenPinned: String?

    var body: some View {
        VStack(spacing: 0) {
            // Como en la app de Twitch: arriba el mensaje fijado y la predicción en curso
            if chat.channel != nil {
                if let pinned = playback.pinnedMessage, pinned != hiddenPinned {
                    // Tocar lo despliega entero (con sus enlaces); la ✕ lo oculta
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "pin.fill").font(.footnote)
                        Text(Self.linked(pinned))
                            .font(.footnote)
                            .lineLimit(pinnedExpanded ? nil : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(.snappy) { pinnedExpanded.toggle() } }
                        Button { withAnimation(.snappy) { hiddenPinned = pinned } } label: {
                            Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Ocultar mensaje fijado")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06))
                }
                if let raid = playback.raidTarget {
                    HStack(spacing: 10) {
                        Label("Raid a \(raid.name) · \(Format.count(raid.viewers)) espectadores", systemImage: "person.3.fill")
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Ir") { playback.followRaid() }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 1, green: 0.62, blue: 0.25))
                            .foregroundStyle(.black)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color(red: 1, green: 0.62, blue: 0.25).opacity(0.14))
                }
                if let poll = playback.poll {
                    Button { showPoll = true } label: { PollBanner(poll: poll) }
                        .buttonStyle(.plain)
                }
                if let train = playback.hypeTrain {
                    HStack(spacing: 10) {
                        Label("Hype train · nivel \(train.level)", systemImage: "train.side.front.car")
                            .font(.footnote.weight(.semibold))
                        ProgressView(value: train.progress).tint(Color(red: 1, green: 0.47, blue: 0.7))
                        Text("\(Int(train.progress * 100)) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(red: 1, green: 0.47, blue: 0.7).opacity(0.12))
                }
                if let prediction = playback.prediction {
                    Button { showPrediction = true } label: { PredictionBanner(prediction: prediction) }
                        .buttonStyle(.plain)
                }
            }
            list.chatTextSize(textSize)
            // Solo en directo se puede escribir; en un VOD el chat es la repetición
            if chat.channel != nil {
                ChatComposer(chat: chat, replyTo: $replyTo)
            }
        }
    }

    /// Texto con sus enlaces pulsables.
    static func linked(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[lower..<upper].link = url
            out[lower..<upper].underlineStyle = .single
        }
        return out
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(chat.messages.reversed()) { message in
                    ChatRow(message: message, onReply: chat.authenticated ? { replyTo = $0 } : nil,
                            onProfile: { profile = $0 }, showTime: timestamps && chat.channel != nil)
                        .modifier(ChatArrival(shownAt: message.shownAt, enabled: animate))
                        .scaleEffect(x: 1, y: -1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .scaleEffect(x: 1, y: -1)
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        // Deslizar el chat cierra el teclado (la lista va volteada: mejor de golpe que "interactivo")
        .scrollDismissesKeyboard(.immediately)
        // En cuanto el dedo toca el chat se congela, para que nada se mueva bajo el dedo.
        // Al soltar: si quedó abajo del todo vuelve a seguir el directo; si no, sigue en pausa.
        .onScrollPhaseChange { _, newPhase in
            phase = newPhase
            if newPhase == .interacting {
                chat.paused = true
            } else if newPhase == .idle, atNewest {
                chat.paused = false
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geo in
            // Volteada: el último mensaje está al principio del contenido
            geo.contentOffset.y + geo.contentInsets.top < 30
        } action: { _, newest in
            atNewest = newest
            if newest, phase == .idle { chat.paused = false }
        }
        .overlay(alignment: .bottom) {
            if chat.paused, !atNewest || chat.pendingCount > 0 {
                Button {
                    chat.paused = false
                    withAnimation { position.scrollTo(edge: .top) }
                } label: {
                    Label(pillTitle, systemImage: "arrow.down")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if chat.messages.isEmpty {
                Text("Esperando mensajes…")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(.snappy, value: chat.paused && (!atNewest || chat.pendingCount > 0))
        .sheet(item: Binding(get: { profile.map(UserLogin.init) }, set: { profile = $0?.id })) { user in
            UserCardView(login: user.id, messages: chat.messages.filter { $0.login == user.id }, chat: chat)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPrediction) {
            if let prediction = playback.prediction { PredictionSheet(prediction: prediction).presentationDetents([.medium, .large]) }
        }
        .sheet(isPresented: $showPoll) {
            if let poll = playback.poll { PollSheet(poll: poll).presentationDetents([.medium]) }
        }
        // Al girar el iPhone se cambia de chat (debajo del vídeo ↔ panel lateral):
        // el que aparece arranca siempre siguiendo el último mensaje
        .onAppear { chat.paused = false }
        .onDisappear { chat.paused = false }
    }

    private var pillTitle: String {
        switch chat.pendingCount {
        case 0: "Volver al chat en vivo"
        case 1: "1 mensaje nuevo"
        default: "\(chat.pendingCount) mensajes nuevos"
        }
    }
}

/// Entrada de un mensaje nuevo: sube un poco y aparece. Solo cambia cómo se dibuja, nunca el
/// sitio que ocupa en la lista, así que ni el scroll ni los toques notan nada.
struct ChatArrival: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// El ajuste "Animar los mensajes nuevos" llega como valor y no como @AppStorage: uno por
    /// fila haría redibujar todas las filas con cada mensaje.
    let enabled: Bool
    @State private var settled: Bool

    init(shownAt: Date?, enabled: Bool) {
        self.enabled = enabled
        // Al volver a un mensaje haciendo scroll también "aparece": ese ya no se anima
        _settled = State(initialValue: (shownAt?.timeIntervalSinceNow ?? -1) < -0.5)
    }

    func body(content: Content) -> some View {
        let still = settled || !enabled
        content
            .opacity(still ? 1 : 0)
            .offset(y: still || reduceMotion ? 0 : 14)
            .scaleEffect(still || reduceMotion ? 1 : 0.94, anchor: .bottomLeading)
            .onAppear {
                guard !settled else { return }
                withAnimation(.spring(duration: 0.4, bounce: 0.3)) { settled = true }
            }
    }
}

/// Chat encima del vídeo a pantalla completa: los últimos mensajes sin fondo, como parte de la
/// imagen. Solo se lee; los toques pasan al vídeo.
struct OverlayChat: View {
    let chat: ChatClient
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("chatTextSize") private var textSize = ChatTextSize.normal
    @AppStorage("chatAnimation") private var animate = true

    var body: some View {
        // El hueco tiene un tamaño fijo y los mensajes cuelgan de su borde de abajo: lo que no
        // cabe sobresale por arriba y lo corta la máscara (un marco flexible lo centraría)
        Color.clear
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(chat.messages.suffix(14)) { message in
                        ChatRow(message: message)
                            .modifier(ChatArrival(shownAt: message.shownAt, enabled: animate))
                            .transition(.opacity)
                    }
                }
                // Cada mensaje con su altura entera, sin recortar emotes para que quepa todo
                .fixedSize(horizontal: false, vertical: true)
                // Aquí no hay scroll que descolocar: los de arriba suben con suavidad
                .animation(reduceMotion || !animate ? nil : .snappy(duration: 0.3), value: chat.messages.last?.id)
                .chatTextSize(textSize)
                .environment(\.colorScheme, .dark)
                // Una sola sombra para todo el bloque: se lee sobre cualquier imagen y cuesta poco
                .compositingGroup()
                .shadow(color: .black.opacity(0.9), radius: 1.5)
                .shadow(color: .black.opacity(0.5), radius: 6)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35)],
                                 startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Si el chat lateral quedó en pausa, aquí no hay forma de reanudarlo
        .onAppear { chat.paused = false }
    }
}

/// Para abrir la ficha de un usuario con `.sheet(item:)`.
struct UserLogin: Identifiable { let id: String }

struct ChatRow: View {
    let message: ChatMessage
    var onReply: ((ChatMessage) -> Void)?
    var onProfile: ((String) -> Void)?
    /// Hora a la izquierda (ajuste del chat, solo en directo).
    var showTime = false
    @Environment(\.openURL) private var openURL

    private static let linkColor = Color(red: 0.45, green: 0.72, blue: 1)

    var body: some View {
        Group {
            // Los mensajes con emotes animados se redibujan ~20 veces por segundo con el
            // fotograma que toca; todos los fotogramas miden lo mismo, así que nada se mueve
            // También mientras falte alguna imagen: si llega tarde, aparece en vez de quedarse el nombre
            if message.emoteURLs.contains(where: { EmoteImages.shared.isAnimated($0) || !EmoteImages.shared.isReady($0) }) {
                TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                    content(at: context.date)
                }
            } else {
                content(at: nil)
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Tocar un mensaje con enlace lo abre; mantener pulsado da a elegir
            .onTapGesture {
                if let url = message.links.first { openURL(url) }
            }
            .contextMenu {
                if let onProfile, !message.login.isEmpty {
                    Button("Ver perfil de \(message.name)", systemImage: "person.crop.circle") { onProfile(message.login) }
                }
                if let onReply, message.ircID != nil, !message.name.isEmpty {
                    Button("Responder", systemImage: "arrowshape.turn.up.left") { onReply(message) }
                }
                if !message.parts.isEmpty {
                    Button("Copiar mensaje", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.plainText }
                }
                ForEach(message.links, id: \.self) { url in
                    Button("Abrir \(url.host() ?? "enlace")", systemImage: "safari") { openURL(url) }
                    Button("Copiar enlace", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
                }
            }
    }

    @ViewBuilder
    private func content(at time: Date?) -> some View {
        let line = rendered(at: time)
        switch message.kind {
        case .event(let event):
            // Tarjeta con icono y barra de color: no se confunde con un mensaje normal
            VStack(alignment: .leading, spacing: 5) {
                Label {
                    Text(verbatim: event.text).font(.footnote.weight(.semibold))
                } icon: {
                    Image(systemName: event.style.icon).foregroundStyle(event.style.tint)
                }
                if !message.parts.isEmpty {
                    line.font(.subheadline)
                }
            }
            .padding(.vertical, 8)
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(event.style.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) {
                Capsule().fill(event.style.tint).frame(width: 3).padding(.vertical, 7).padding(.leading, 4)
            }
            .padding(.vertical, 2)
        case .highlighted:
            withReply(line.font(.subheadline))
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.glint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .normal where message.mentionsMe:
            // Te mencionan: resaltado, como en la app de Twitch
            withReply(line.font(.subheadline))
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 1, green: 0.35, blue: 0.35).opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .normal:
            withReply(line.font(.subheadline))
        }
    }

    private func withReply(_ text: some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let reply = message.reply {
                Label {
                    Text(verbatim: reply).lineLimit(1)
                } icon: {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            text
        }
    }

    private func rendered(at time: Date?) -> Text {
        let emotes = EmoteImages.shared
        var text = Text(verbatim: "")
        if showTime {
            text = Text(verbatim: message.date.formatted(date: .omitted, time: .shortened) + " ").font(.caption).foregroundStyle(.tertiary)
        }
        // Insignias delante del nombre (mod, VIP, sub…), como en la app de Twitch
        for url in message.badgeURLs {
            if let image = emotes.image(url) {
                text = Text("\(text)\(Text(Image(uiImage: image)).baselineOffset(-3)) ")
            }
        }
        text = Text("\(text)\(Text(verbatim: message.name).bold().foregroundStyle(message.color))")
        text = Text("\(text)\(Text(verbatim: message.isAction ? " " : ": ").foregroundStyle(.secondary))")
        for part in message.parts {
            switch part {
            case .text(let string):
                var piece = Text(verbatim: string)
                if message.isAction { piece = piece.italic().foregroundStyle(message.color) }
                text = Text("\(text)\(piece)")
            case .emote(let url, let name):
                if let image = emotes.image(url, at: time) {
                    text = Text("\(text)\(Text(Image(uiImage: image)).baselineOffset(-5))")
                } else {
                    text = Text("\(text)\(Text(verbatim: name))")
                }
            case .mention(let name):
                text = Text("\(text)\(Text(verbatim: name).bold().foregroundStyle(Color.glint))")
            case .link(let display, _):
                text = Text("\(text)\(Text(verbatim: display).underline().foregroundStyle(Self.linkColor))")
            }
        }
        return text
    }
}

extension ChatMessage.Event.Style {
    var icon: String {
        switch self {
        case .sub: "star.fill"
        case .gift: "gift.fill"
        case .raid: "person.3.fill"
        case .announcement: "megaphone.fill"
        case .bits: "diamond.fill"
        case .other: "sparkles"
        case .notice: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .sub: .glint
        case .gift: Color(red: 1, green: 0.47, blue: 0.7)
        case .raid: Color(red: 1, green: 0.62, blue: 0.25)
        case .announcement: Color(red: 0.45, green: 0.68, blue: 1)
        case .bits: Color(red: 0.72, green: 0.52, blue: 1)
        case .other: Color(red: 1, green: 0.85, blue: 0.35)
        case .notice: Color(white: 0.6)
        }
    }
}

/// Tarjeta de predicción encima del chat: título y cómo va cada opción.
struct PredictionBanner: View {
    let prediction: Twitch.Prediction

    var body: some View {
        let total = max(1, prediction.outcomes.map(\.points).reduce(0, +))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(prediction.title, systemImage: "chart.bar.fill").font(.footnote.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 8)
                Text(prediction.locked ? "Cerrada" : "Participar").font(.caption.weight(.semibold))
                    .foregroundStyle(prediction.locked ? Color.secondary : Color.glint)
            }
            ForEach(Array(prediction.outcomes.enumerated()), id: \.offset) { _, outcome in
                HStack(spacing: 8) {
                    Text(outcome.title).font(.caption).lineLimit(1)
                    Spacer()
                    Text("\(Int((Double(outcome.points) / Double(total) * 100).rounded())) % · \(Format.count(outcome.points))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.glint.opacity(0.1))
    }
}

/// Ficha de un usuario del chat: quién es, desde cuándo tiene cuenta y lo que ha escrito aquí.
struct UserCardView: View {
    let login: String
    let messages: [ChatMessage]
    let chat: ChatClient
    @Environment(Router.self) private var router
    @Environment(Playback.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @State private var card: Twitch.UserCard?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Avatar(url: card?.profileImageURL, size: 60)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card?.displayName ?? login).font(.headline)
                            if let created = card?.createdAt {
                                Text("Cuenta creada el \(created.formatted(date: .long, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let followers = card?.followers?.totalCount {
                                Text("\(Format.count(followers)) seguidores").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let bio = card?.description, !bio.isEmpty {
                        Text(bio).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Ver canal", systemImage: "person.crop.square") {
                        dismiss()
                        playback.minimized = true
                        router.open(.channel(login))
                    }
                    // Como "Bloquear" en la app de Twitch, pero solo en este iPhone
                    let hidden = ChatClient.hidden.contains(login)
                    Button(hidden ? "Volver a ver sus mensajes" : "Ocultar sus mensajes",
                           systemImage: hidden ? "eye" : "eye.slash", role: hidden ? nil : .destructive) {
                        chat.setHidden(login, !hidden)
                        dismiss()
                    }
                }
                if !messages.isEmpty {
                    Section("En este chat") {
                        ForEach(messages.suffix(20).reversed()) { ChatRow(message: $0) }
                    }
                }
            }
            .navigationTitle(card?.displayName ?? login)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
        .task { card = await Twitch.userCard(login) }
    }
}

/// Tarjeta de encuesta encima del chat: la pregunta y cómo van los votos.
struct PollBanner: View {
    let poll: Twitch.Poll

    var body: some View {
        let total = max(1, poll.choices.map(\.votes).reduce(0, +))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(poll.title, systemImage: "checklist").font(.footnote.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 8)
                Text("Votar").font(.caption.weight(.semibold)).foregroundStyle(Color.glint)
            }
            ForEach(Array(poll.choices.enumerated()), id: \.offset) { _, choice in
                HStack(spacing: 8) {
                    Text(choice.title).font(.caption).lineLimit(1)
                    Spacer()
                    Text("\(Int((Double(choice.votes) / Double(total) * 100).rounded())) % · \(Format.count(choice.votes))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(red: 0.45, green: 0.68, blue: 1).opacity(0.1))
    }
}

/// Apostar en la predicción desde la app: eliges cuántos puntos y a qué opción.
struct PredictionSheet: View {
    let prediction: Twitch.Prediction
    @Environment(Account.self) private var account
    @Environment(Playback.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @State private var balance: Int?
    @State private var points = 100.0
    @State private var working = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(prediction.title).font(.headline)
                    if prediction.locked {
                        Label("Las apuestas están cerradas", systemImage: "lock.fill").foregroundStyle(.secondary)
                    }
                }
                if !prediction.locked {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Apostar \(Int(points).formatted()) puntos").font(.subheadline.weight(.semibold)).monospacedDigit()
                            Slider(value: $points, in: 10...max(10, Double(min(balance ?? 250_000, 250_000))), step: 10)
                            if let balance { Text("Tienes \(balance.formatted())").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section {
                    let total = max(1, prediction.outcomes.map(\.points).reduce(0, +))
                    ForEach(prediction.outcomes, id: \.id) { outcome in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(outcome.title).font(.subheadline.weight(.medium))
                                Text("\(Int((Double(outcome.points) / Double(total) * 100).rounded())) % · \(Format.count(outcome.points)) puntos")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !prediction.locked {
                                Button("Apostar") { Task { await bet(outcome.id) } }
                                    .buttonStyle(.borderedProminent).tint(Color.glint).foregroundStyle(.black)
                                    .disabled(working)
                            }
                        }
                    }
                }
                if let result {
                    Section { Text(result) }
                }
            }
            .navigationTitle("Predicción")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
        .task {
            if let token = account.token, let login = playback.login {
                balance = await Twitch.pointsBalance(login, token: token)
                if let balance { points = Double(min(100, max(10, balance))) }
            }
        }
    }

    private func bet(_ outcomeID: String) async {
        guard let token = account.token else { return }
        working = true
        defer { working = false }
        do {
            try await Twitch.makePrediction(eventID: prediction.id, outcomeID: outcomeID, points: Int(points), token: token)
            result = "Apuesta hecha: \(Int(points).formatted()) puntos."
        } catch {
            result = error.localizedDescription
        }
    }
}

/// Votar en la encuesta desde la app.
struct PollSheet: View {
    let poll: Twitch.Poll
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            List {
                Section { Text(poll.title).font(.headline) }
                Section {
                    ForEach(poll.choices, id: \.id) { choice in
                        Button { Task { await vote(choice.id) } } label: {
                            HStack {
                                Text(choice.title)
                                Spacer()
                                Text("\(Format.count(choice.votes)) votos").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(working)
                    }
                }
                if let result {
                    Section { Text(result) }
                }
            }
            .navigationTitle("Encuesta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
    }

    private func vote(_ choiceID: String) async {
        guard let token = account.token, let userID = account.user?.id else { return }
        working = true
        defer { working = false }
        do {
            try await Twitch.voteInPoll(pollID: poll.id, choiceID: choiceID, userID: userID, token: token)
            result = "Voto enviado."
        } catch {
            result = error.localizedDescription
        }
    }
}
