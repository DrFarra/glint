import SwiftUI

/// Tus mensajes privados (whispers), como en la app de Twitch: cada conversación con la última
/// frase y los no leídos.
struct WhispersView: View {
    @Environment(Account.self) private var account
    @State private var threads: [Twitch.WhisperThread]?
    @State private var failure: String?

    var body: some View {
        List {
            if let failure {
                Section { Text(failure).foregroundStyle(.secondary) }
            }
            ForEach(threads ?? []) { thread in
                let other = thread.other(than: account.user?.login)
                NavigationLink {
                    WhisperThreadView(thread: thread)
                } label: {
                    HStack(spacing: 12) {
                        Avatar(url: other?.profileImageURL, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(other?.displayName ?? other?.login ?? "?").font(.subheadline.weight(.semibold))
                            Text(thread.messages?.edges?.first?.node?.content?.content ?? "")
                                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let unread = thread.unreadMessagesCount, unread > 0 {
                            Text("\(unread)").font(.caption.weight(.bold)).foregroundStyle(.black)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.glint, in: Capsule())
                        }
                    }
                }
            }
        }
        .overlay {
            if threads == nil, failure == nil {
                ProgressView()
            } else if threads?.isEmpty == true, failure == nil {
                ContentUnavailableView("Sin mensajes", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Los mensajes privados de Twitch aparecerán aquí."))
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .navigationTitle("Mensajes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func load() async {
        guard let token = account.token else { return }
        // En una tarea propia: SwiftUI cancela la de "tirar para recargar"
        switch await Task(operation: { try await Twitch.whisperThreads(token: token) }).result {
        case .success(let loaded):
            threads = loaded
            failure = nil
        case .failure(let error):
            failure = "No se pudieron cargar tus mensajes: \(error.localizedDescription)"
        }
    }
}

/// Una conversación privada: los mensajes (se refrescan solos) y la caja para responder.
struct WhisperThreadView: View {
    let thread: Twitch.WhisperThread
    @Environment(Account.self) private var account
    @State private var messages: [Twitch.WhisperThread.Message] = []
    @State private var text = ""
    @State private var sending = false
    @State private var failure: String?

    private var other: Twitch.WhisperThread.Participant? { thread.other(than: account.user?.login) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                            bubble(message).id(index)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: messages.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(Color.live).padding(.horizontal, 14)
            }
            HStack(spacing: 8) {
                TextField("Mensaje a \(other?.displayName ?? "")", text: $text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.surface, in: Capsule())
                    .submitLabel(.send)
                    .onSubmit { Task { await send() } }
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || sending)
            }
            .padding(10)
        }
        .navigationTitle(other?.displayName ?? other?.login ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Mientras está abierta se mira cada 10 s si hay mensajes nuevos
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func bubble(_ message: Twitch.WhisperThread.Message) -> some View {
        let mine = message.from?.login == account.user?.login
        return HStack {
            if mine { Spacer(minLength: 40) }
            Text(message.content?.content ?? "")
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(mine ? .black : .primary)
                .background(mine ? Color.glint : Color.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !mine { Spacer(minLength: 40) }
        }
    }

    private func load() async {
        guard let token = account.token else { return }
        if let loaded = try? await Twitch.whispers(thread: thread.id, token: token) { messages = loaded }
    }

    private func send() async {
        let body = text.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty, let token = account.token, let id = other?.id else { return }
        sending = true
        defer { sending = false }
        do {
            try await Twitch.sendWhisper(body, to: id, token: token)
            text = ""
            failure = nil
            await load()
        } catch {
            failure = "No se pudo enviar: \(error.localizedDescription)"
        }
    }
}
