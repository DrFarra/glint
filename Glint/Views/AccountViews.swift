import SwiftUI
import WebKit

// MARK: - Cuenta

/// Botón de la barra de Inicio: tu avatar, o el icono de perfil si no has iniciado sesión.
struct AccountButton: View {
    @Environment(Account.self) private var account
    @Environment(Router.self) private var router

    var body: some View {
        Button { router.showAccount = true } label: {
            if let user = account.user {
                Avatar(url: user.profileImageURL, size: 30)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        .accessibilityLabel(account.user.map { "Cuenta de \($0.displayName)" } ?? "Iniciar sesión")
    }
}

struct AccountView: View {
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var showLogin: Bool
    @State private var working = false
    @State private var failure: String?

    init(startAtLogin: Bool = false) {
        _showLogin = State(initialValue: startAtLogin)
    }

    var body: some View {
        NavigationStack {
            List {
                if let user = account.user {
                    Section {
                        HStack(spacing: 14) {
                            Avatar(url: user.profileImageURL, size: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName).font(.headline)
                                Text(verbatim: "@\(user.login)").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        NavigationLink { WhispersView() } label: {
                            Label("Mensajes", systemImage: "bubble.left.and.bubble.right")
                        }
                        NavigationLink { DropsView() } label: {
                            Label("Drops", systemImage: "gift")
                        }
                    }
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Inicia sesión con Twitch").font(.headline)
                            Text("Para escribir en el chat, usar los emotes de tus suscripciones, ver tus canales seguidos y canjear puntos o participar en predicciones.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        Button {
                            failure = nil
                            showLogin = true
                        } label: {
                            Label("Iniciar sesión", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .disabled(working)
                    } footer: {
                        Text("Escribes tu usuario y contraseña en la página de Twitch: Glint no los ve. Glint no es una app oficial de Twitch.")
                    }
                    if working {
                        Section { ProgressView("Entrando…") }
                    }
                    if let failure {
                        Section { Text(failure).foregroundStyle(Color.live) }
                    }
                }
                // Los ajustes aquí mismo: antes estaban una pantalla más adentro
                SettingsSections()
                if account.user != nil {
                    Section {
                        Button("Cerrar sesión", role: .destructive) {
                            Task { await account.signOut() }
                        }
                    }
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } }
            }
            .navigationDestination(isPresented: $showLogin) {
                TwitchWebView(url: URL(string: "https://www.twitch.tv/login")!, onToken: signIn)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Twitch")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func signIn(_ token: String) {
        showLogin = false
        working = true
        Task {
            do {
                try await account.signIn(token: token)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: - Web de Twitch

/// Página de Twitch con la sesión del usuario (la misma en toda la app). Con `onToken`,
/// avisa en cuanto Twitch guarda la cookie de sesión tras iniciar sesión.
struct TwitchWebView: UIViewRepresentable {
    let url: URL
    var desktop = false
    var onToken: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.preferredContentMode = desktop ? .desktop : .mobile
        config.allowsInlineMediaPlayback = true
        // Que la web no se ponga a reproducir el directo a la vez que el reproductor
        config.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .black
        view.load(URLRequest(url: url))
        if let onToken { context.coordinator.watch(config.websiteDataStore.httpCookieStore, onToken) }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.task?.cancel()
    }

    @MainActor
    final class Coordinator {
        var task: Task<Void, Never>?

        func watch(_ store: WKHTTPCookieStore, _ onToken: @escaping (String) -> Void) {
            task = Task {
                while !Task.isCancelled {
                    let cookies = await store.allCookies()
                    if let cookie = cookies.first(where: { $0.name == "auth-token" && $0.domain.hasSuffix("twitch.tv") && !$0.value.isEmpty }) {
                        onToken(cookie.value)
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }
}

/// Hoja con una página de Twitch: seguir canales, puntos, predicciones y encuestas.
struct TwitchWebSheet: View {
    let title: String
    let url: URL
    var hint: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TwitchWebView(url: url, desktop: true)
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let hint {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.bar)
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } }
                }
        }
    }
}

// MARK: - Escribir en el chat

/// Barra para escribir en el chat del directo. Sin sesión, invita a iniciarla.
struct ChatComposer: View {
    let chat: ChatClient
    @Binding var replyTo: ChatMessage?
    @Environment(Account.self) private var account
    @Environment(Router.self) private var router
    @State private var text = ""
    @State private var showEmotes = false
    @State private var showPoints = false
    @State private var points: Int?
    /// Desde cuándo sigues el canal (para el modo solo seguidores); nil = no se sabe.
    @State private var followedAt: Date?? = nil
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chat.roomModes.isEmpty {
                Label(chat.roomModes.joined(separator: " · "), systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let replyTo {
                HStack(spacing: 6) {
                    Label("Respondiendo a \(replyTo.name)", systemImage: "arrowshape.turn.up.left.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button { self.replyTo = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Cancelar respuesta")
                }
            }
            if account.isLoggedIn, let reason = chat.writeBlock(followedAt: followedAt) {
                // Sin caja de texto: si no puedes escribir, que no lo parezca
                HStack(spacing: 8) {
                    Label(reason, systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    pointsButton
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            } else if account.isLoggedIn {
                if !suggestions.isEmpty { suggestionBar }
                inputRow
            } else {
                Button { router.showAccount = true } label: {
                    Label("Inicia sesión para chatear", systemImage: "person.crop.circle")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.surface, in: Capsule())
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .sheet(isPresented: $showEmotes) {
            EmotePicker(chat: chat) { insert($0) }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPoints, onDismiss: refreshPoints) {
            if let channel = chat.channel {
                PointsView(login: channel)
            }
        }
        .task(id: "\(chat.channel ?? "")-\(account.user?.id ?? "")") {
            followedAt = nil
            guard account.isLoggedIn else { return }
            refreshPoints()
            if let token = account.token, let channel = chat.channel {
                followedAt = await Twitch.followedAt(channel, token: token)
            }
            await account.loadEmotes()
        }
        .onChange(of: replyTo?.id) { _, id in if id != nil { focused = true } }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Button { showEmotes = true } label: {
                Image(systemName: "face.smiling").font(.title3).frame(width: 32, height: 36)
            }
            .accessibilityLabel("Emotes")

            TextField(chat.authenticated ? "Enviar un mensaje" : "Conectando al chat…", text: $text)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.surface, in: Capsule())
                .onChange(of: text) { _, value in
                    if value.count > 500 { text = String(value.prefix(500)) }
                }

            if text.isEmpty, focused {
                Button { focused = false } label: {
                    Image(systemName: "keyboard.chevron.compact.down").font(.title3).frame(width: 32, height: 36)
                }
                .accessibilityLabel("Ocultar teclado")
            } else if text.isEmpty {
                pointsButton
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2).frame(width: 32, height: 36)
                }
                .disabled(!chat.authenticated)
                .accessibilityLabel("Enviar")
            }
        }
        .buttonStyle(.plain)
    }

    /// Lo que se está escribiendo: la última palabra.
    private var lastWord: Substring { text.split(separator: " ", omittingEmptySubsequences: false).last ?? "" }

    /// Autocompletar como en la app de Twitch: emotes por su nombre y "@" + gente que ha escrito.
    private var suggestions: [(name: String, url: String?)] {
        let word = lastWord.lowercased()
        guard word.count >= 2 else { return [] }
        if word.hasPrefix("@") {
            let prefix = word.dropFirst()
            var seen = Set<String>()
            return chat.messages.reversed().compactMap { message -> (name: String, url: String?)? in
                guard !message.login.isEmpty, message.login.hasPrefix(prefix), seen.insert(message.login).inserted else { return nil }
                return (name: "@\(message.name)", url: nil)
            }.prefix(8).map { $0 }
        }
        let emotes = chat.channelEmotes + account.emoteSets.flatMap { set in set.emotes.map { (name: $0.token, url: $0.url) } }
        var seen = Set<String>()
        return emotes.filter { $0.name.lowercased().hasPrefix(word) && seen.insert($0.name).inserted }
            .prefix(12).map { (name: $0.name, url: Optional($0.url)) }
    }

    private var suggestionBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                    Button {
                        text = String(text.dropLast(lastWord.count)) + suggestion.name + " "
                    } label: {
                        HStack(spacing: 5) {
                            if let url = suggestion.url { EmoteCell(url: url).frame(width: 24, height: 24) }
                            Text(suggestion.name).font(.footnote.weight(.medium)).lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var pointsButton: some View {
        Button { showPoints = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "star.circle.fill")
                if let points { Text(Format.count(points)).monospacedDigit() }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.glint)
            .frame(minWidth: 32, minHeight: 36)
        }
        .accessibilityLabel(points.map { "\(Format.count($0)) puntos del canal. Puntos, predicciones y encuestas" }
                            ?? "Puntos, predicciones y encuestas")
    }

    private func send() {
        guard chat.send(text, replyingTo: replyTo) else { return }
        text = ""
        replyTo = nil
    }

    private func insert(_ token: String) {
        if !text.isEmpty, !text.hasSuffix(" ") { text += " " }
        text += token + " "
    }

    private func refreshPoints() {
        guard let token = account.token, let channel = chat.channel else { return }
        Task { points = await Twitch.pointsBalance(channel, token: token) }
    }
}

/// Un emote del selector, de la misma caché que el chat: los que ya salieron en el chat aparecen
/// al instante y los que se bajan aquí ya estarán listos cuando alguien los use.
private struct EmoteCell: View {
    let url: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.surface)
            }
        }
        .task(id: url) { image = await EmoteImages.shared.loaded(url) }
    }
}

/// Tus emotes de Twitch y los de 7TV/BTTV/FFZ del canal. Tocar uno lo añade al mensaje.
struct EmotePicker: View {
    let chat: ChatClient
    let onPick: (String) -> Void
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20, pinnedViews: .sectionHeaders) {
                    let channel = chat.channelEmotes
                    if !channel.isEmpty {
                        section("Del canal · 7TV, BTTV, FFZ", channel)
                    }
                    ForEach(account.emoteSets) { set in
                        section(set.owner, set.emotes.map { (name: $0.token, url: $0.url) })
                    }
                    if channel.isEmpty, account.emoteSets.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .navigationTitle("Emotes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } }
            }
        }
    }

    private func section(_ title: String, _ emotes: [(name: String, url: String)]) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
                ForEach(Array(emotes.enumerated()), id: \.offset) { _, emote in
                    Button { onPick(emote.name) } label: {
                        EmoteCell(url: emote.url)
                            .frame(width: 32, height: 32)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel(emote.name)
                }
            }
        } header: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .background(.background)
        }
    }
}
