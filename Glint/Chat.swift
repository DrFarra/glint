import ImageIO
import Observation
import SwiftUI
import UIKit

struct ChatMessage: Identifiable {
    enum Part {
        case text(String)
        case emote(url: String, name: String)
        case mention(String)
        case link(String, URL)
    }

    /// Avisos de Twitch: suscripciones, regalos, raids, anuncios y bits.
    struct Event {
        enum Style { case sub, gift, raid, announcement, bits, other, notice }
        let style: Style
        let text: String
    }

    enum Kind {
        case normal
        /// "Destacar mi mensaje" con puntos del canal.
        case highlighted
        case event(Event)
    }

    let id = UUID()
    let name: String
    let color: Color
    var parts: [Part]
    let isAction: Bool
    var kind: Kind = .normal
    /// "Nombre: mensaje" al que responde.
    var reply: String?
    /// Id del mensaje en Twitch (para responderlo o borrarlo) y usuario que lo escribió.
    var ircID: String?
    var login = ""
    /// Cuándo entró en el chat a su ritmo normal (nil si llegó de golpe: al saltar o al soltar los
    /// retenidos). Solo esos se animan al aparecer.
    var shownAt: Date?

    var plainText: String {
        parts.map { part in
            switch part {
            case .text(let s), .mention(let s), .link(let s, _): s
            case .emote(_, let name): name
            }
        }.joined()
    }

    var links: [URL] {
        parts.compactMap { part in
            if case .link(_, let url) = part { return url }
            return nil
        }
    }

    var emoteURLs: [String] {
        parts.compactMap { part in
            if case .emote(let url, _) = part { return url }
            return nil
        }
    }
}

private let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

/// Chat por IRC de Twitch: con la sesión del usuario si la hay (y entonces se puede
/// escribir), si no como anónimo (justinfan). En un VOD reproduce el chat original
/// al ritmo del vídeo.
///
/// Para que corra suave: cada mensaje espera a que sus emotes estén descargados
/// (así nunca se ve el nombre del emote y luego la imagen), y los mensajes salen a
/// ritmo constante en vez de a ráfagas.
@MainActor @Observable
final class ChatClient {
    private(set) var messages: [ChatMessage] = []
    private(set) var pendingCount = 0
    /// Mientras el usuario lee mensajes antiguos, los nuevos esperan aparte.
    var paused = false { didSet { if !paused, oldValue { releaseHeld() } } }
    /// Canal del directo (nil en un VOD): solo ahí se puede escribir.
    private(set) var channel: String?
    /// Conectado con la cuenta del usuario: se puede escribir.
    private(set) var authenticated = false
    /// Modo lento, solo seguidores… en palabras.
    private(set) var roomModes: [String] = []

    @ObservationIgnored private var pendingSends: [(text: String, reply: ChatMessage?, sent: Date)] = []
    @ObservationIgnored private var userColor: Substring?
    @ObservationIgnored private var userName: String?
    @ObservationIgnored private var room: [String: String] = [:]
    /// Twitch rechazó el token en el chat: se sigue como anónimo hasta volver a iniciar sesión.
    @ObservationIgnored private var authFailed = false

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pump: Task<Void, Never>?
    /// Recibidos, en orden de llegada, esperando a sus emotes.
    @ObservationIgnored private var staged: [(message: ChatMessage, arrived: Date)] = []
    /// Listos para mostrarse; se van soltando poco a poco.
    @ObservationIgnored private var ready: [ChatMessage] = []
    @ObservationIgnored private var held: [ChatMessage] = []
    /// Emotes de 7TV, BTTV y FFZ del canal: nombre → URL.
    @ObservationIgnored private var extraEmotes: [String: String] = [:]
    @ObservationIgnored private var emoteTask: Task<Void, Never>?
    /// Lista de emotes de 7TV/BTTV/FFZ ya descargada. Hasta entonces los mensajes del
    /// directo esperan en `waiting`: si no, se quedarían con el emote como texto.
    @ObservationIgnored private var emotesLoaded = false
    @ObservationIgnored private var waiting: [(message: ChatMessage, arrived: Date)] = []

    func loadEmotes(channelID: String?) {
        emoteTask?.cancel()
        // La lista guardada de la última vez sirve al instante; la de 7TV de un canal grande
        // tarda varios segundos en llegar
        if let cached = ThirdPartyEmotes.cached(channelID: channelID) { apply(cached) }
        emoteTask = Task { [weak self] in
            await ThirdPartyEmotes.load(channelID: channelID) { emotes in
                guard !Task.isCancelled else { return }
                self?.apply(emotes)
            }
            if !Task.isCancelled { self?.markEmotesLoaded() }
        }
    }

    /// Nueva lista de emotes: también se aplica a los mensajes que ya llegaron, para que
    /// los que salieron antes de tenerla no se queden con el nombre del emote como texto.
    private func apply(_ emotes: [String: String]) {
        // Se suma a lo que ya había (p. ej. la lista guardada) en vez de reemplazarlo
        extraEmotes.merge(emotes) { _, newer in newer }
        if emotesLoaded {
            messages = messages.map(expand)
            held = held.map(expand)
            ready = ready.map(expand)
            staged = staged.map { (message: expand($0.message), arrived: $0.arrived) }
            for message in messages + held { EmoteImages.shared.prefetch(message.emoteURLs) }
        }
        markEmotesLoaded()
    }

    private func markEmotesLoaded() {
        guard !emotesLoaded else { return }
        emotesLoaded = true
        for item in waiting { stage(expand(item.message)) }
        waiting = []
    }

    func connect(_ channel: String) {
        disconnect()
        self.channel = channel.lowercased()
        startPump()
        openSocket()
    }

    /// Tras iniciar o cerrar sesión: vuelve a entrar al chat con la nueva identidad.
    func reconnect() {
        guard channel != nil else { return }
        authFailed = false
        openSocket()
    }

    private func openSocket() {
        guard let channel else { return }
        loop?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        pendingSends = []
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.run(channel)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Emotes de 7TV, BTTV y FFZ del canal, por nombre.
    var channelEmotes: [(name: String, url: String)] {
        extraEmotes.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { (name: $0.key, url: $0.value) }
    }

    // MARK: - Escribir

    /// Envía un mensaje (o una respuesta). Se muestra cuando Twitch lo confirma.
    @discardableResult
    func send(_ raw: String, replyingTo parent: ChatMessage? = nil) -> Bool {
        let text = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let socket, let channel, authenticated else { return false }
        var body = text
        if text.hasPrefix("/me ") {
            body = "\u{1}ACTION \(text.dropFirst(4))\u{1}"
        } else if text.hasPrefix("/") {
            notice("Los comandos de Twitch no funcionan desde la app (salvo /me).")
            return false
        }
        let tags = parent?.ircID.map { "@reply-parent-msg-id=\($0) " } ?? ""
        pendingSends.append((text: text, reply: parent, sent: .now))
        paused = false
        Task { try? await socket.send(.string("\(tags)PRIVMSG #\(channel) :\(body)")) }
        return true
    }

    /// Twitch no devuelve tus propios mensajes: al confirmarlos (USERSTATE con id) se pintan aquí.
    private func echo(_ pending: (text: String, reply: ChatMessage?, sent: Date), id: String) {
        let account = Account.shared
        let login = account.user?.login ?? ""
        var text = pending.text
        let isAction = text.hasPrefix("/me ")
        if isAction { text = String(text.dropFirst(4)) }
        var parts: [ChatMessage.Part] = []
        var run = ""
        for (i, word) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let separator = i == 0 ? "" : " "
            if let emoteID = account.emoteIDs[String(word)] {
                run += separator
                if !run.isEmpty { parts.append(.text(run)) }
                run = ""
                parts.append(.emote(url: Self.twitchEmoteURL(emoteID), name: String(word)))
            } else {
                run += separator + word
            }
        }
        if !run.isEmpty { parts.append(.text(run)) }
        let name = userName.flatMap { $0.isEmpty ? nil : $0 } ?? account.user?.displayName ?? login
        var message = ChatMessage(name: name, color: Self.color(userColor, name: login),
                                  parts: Self.annotate(parts), isAction: isAction)
        message.ircID = id
        message.login = login
        if let reply = pending.reply { message.reply = "\(reply.name): \(reply.plainText)" }
        receive(message)
    }

    /// Aviso de Twitch o de la app dentro del chat.
    private func notice(_ text: String) {
        receive(ChatMessage(name: "", color: .secondary, parts: [], isAction: false,
                            kind: .event(.init(style: .notice, text: text))))
    }

    /// Líneas IRC que no son mensajes: confirmaciones, avisos, modos del chat y borrados.
    private func control(_ line: String) {
        let (tags, rest) = Self.splitTags(line)
        let trailing = rest.range(of: " :").map { String(rest[$0.upperBound...]) } ?? ""
        // Lo que se envió hace más de 10 s sin respuesta se da por perdido
        pendingSends.removeAll { $0.sent.timeIntervalSinceNow < -10 }
        if rest.contains(" USERSTATE #") {
            userColor = tags["color"]
            userName = tags["display-name"].map(Self.unescape)
            if let id = tags["id"], !pendingSends.isEmpty {
                echo(pendingSends.removeFirst(), id: String(id))
            }
        } else if rest.contains(" NOTICE ") {
            let id = tags["msg-id"].map(String.init) ?? ""
            if trailing.contains("Login authentication failed") || trailing.contains("Improperly formatted auth") {
                authFailed = true
                authenticated = false
                notice("Twitch no aceptó tu sesión en el chat. Cierra sesión y vuelve a entrar.")
                return
            }
            if id.hasPrefix("msg_"), !pendingSends.isEmpty { pendingSends.removeFirst() }
            if !trailing.isEmpty { notice(Self.translate(notice: id, trailing)) }
        } else if rest.contains(" ROOMSTATE #") {
            for key in ["emote-only", "followers-only", "slow", "subs-only"] {
                if let value = tags[Substring(key)] { room[key] = String(value) }
            }
            roomModes = Self.describe(room)
        } else if rest.contains(" CLEARMSG #"), let target = tags["target-msg-id"].map(String.init) {
            remove { $0.ircID == target }
        } else if rest.contains(" CLEARCHAT #") {
            if trailing.isEmpty {
                remove { _ in true }
                notice("Un moderador ha vaciado el chat.")
            } else {
                remove { $0.login == trailing }
            }
        }
    }

    private func remove(where match: (ChatMessage) -> Bool) {
        messages.removeAll(where: match)
        held.removeAll(where: match)
        ready.removeAll(where: match)
        staged.removeAll { match($0.message) }
        pendingCount = held.count
    }

    nonisolated static func describe(_ room: [String: String]) -> [String] {
        var modes: [String] = []
        if let slow = room["slow"].flatMap({ Int($0) }), slow > 0 { modes.append("Modo lento: \(slow) s") }
        if let followers = room["followers-only"].flatMap({ Int($0) }), followers >= 0 {
            modes.append(followers == 0 ? "Solo seguidores" : "Solo seguidores desde hace \(duration(minutes: followers))")
        }
        if room["subs-only"] == "1" { modes.append("Solo suscriptores") }
        if room["emote-only"] == "1" { modes.append("Solo emotes") }
        return modes
    }

    /// 129600 → "3 meses", 1440 → "1 día", 90 → "2 h".
    nonisolated static func duration(minutes: Int) -> String {
        let (months, days, hours) = (minutes / 43_200, minutes / 1_440, (minutes + 30) / 60)
        if months > 0 { return months == 1 ? "1 mes" : "\(months) meses" }
        if days > 0 { return days == 1 ? "1 día" : "\(days) días" }
        if minutes >= 60 { return "\(hours) h" }
        return "\(minutes) min"
    }

    nonisolated static func translate(notice id: String, _ text: String) -> String {
        switch id {
        case "msg_slowmode": "El chat está en modo lento: espera un poco para volver a escribir."
        case "msg_followersonly", "msg_followersonly_zero", "msg_followersonly_followed":
            "Solo pueden escribir los seguidores del canal."
        case "msg_subsonly": "Solo pueden escribir los suscriptores."
        case "msg_emoteonly": "El chat está en modo solo emotes."
        case "msg_duplicate": "No puedes enviar el mismo mensaje dos veces seguidas."
        case "msg_ratelimit": "Estás escribiendo demasiado rápido."
        case "msg_banned": "Tienes prohibido escribir en este chat."
        case "msg_verified_email": "Tienes que verificar tu email en Twitch para escribir aquí."
        case "msg_requires_verified_phone_number": "Este canal pide un teléfono verificado en tu cuenta de Twitch."
        default: text
        }
    }

    /// Chat de un VOD: pide los mensajes por tramos (~30 s por delante, con sus
    /// emotes ya descargándose) y los suelta cuando el vídeo llega a su segundo.
    func replay(videoID: String, position: @escaping () -> Double) {
        disconnect()
        startPump()
        loop = Task { [weak self] in
            var queue: [(time: Double, message: ChatMessage)] = []
            var cursor = 0.0, fetchedUntil = -1.0, last = -100.0
            var finished = false, jumped = false
            var jumpDeadline: Date?
            // Los mensajes se convierten a emotes al pedirlos: primero hace falta la lista de emotes
            let start = Date()
            while self?.emotesLoaded == false, Date().timeIntervalSince(start) < 3, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.markEmotesLoaded()
            while !Task.isCancelled {
                guard let self else { return }
                let now = position()
                if now < last - 2 || now > last + 20 {
                    // Salto en el vídeo: se pide el chat desde ahí, con 20 s de contexto
                    queue = []
                    cursor = max(0, now - 20)
                    fetchedUntil = cursor - 1
                    finished = false
                    jumped = true
                    jumpDeadline = nil
                }
                last = now
                if !finished, fetchedUntil < now + 30,
                   let page = try? await Twitch.comments(video: videoID, at: Int(cursor)) {
                    let fresh = page.comments.filter { Double($0.contentOffsetSeconds ?? 0) > fetchedUntil }
                    let items = fresh.map { (time: Double($0.contentOffsetSeconds ?? 0), message: message(from: $0)) }
                    for item in items { EmoteImages.shared.prefetch(item.message.emoteURLs) }
                    queue += items
                    if let end = fresh.last?.contentOffsetSeconds {
                        fetchedUntil = Double(end)
                        cursor = fetchedUntil + 1
                    } else if page.more {
                        cursor += 30
                    } else {
                        finished = true
                    }
                }
                let due = queue.prefix { $0.time <= now }.count
                let batchReady = queue.prefix(due).allSatisfy { item in
                    item.message.emoteURLs.allSatisfy { EmoteImages.shared.isReady($0) }
                }
                if jumped, fetchedUntil >= now || finished {
                    jumpDeadline = jumpDeadline ?? Date(timeIntervalSinceNow: 1.2)
                }
                if jumped, let deadline = jumpDeadline, batchReady || Date() > deadline {
                    // Se cambia el chat entero de una vez, con sus emotes ya cargados:
                    // sin vaciarlo antes ni ver cómo se rellena
                    jumpDeadline = nil
                    staged = []
                    ready = []
                    held = []
                    pendingCount = 0
                    messages = queue.prefix(due).map { $0.message }
                    queue.removeFirst(due)
                    jumped = false
                } else if !jumped {
                    for item in queue.prefix(due) { stage(item.message) }
                    queue.removeFirst(due)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func disconnect() {
        loop?.cancel()
        pump?.cancel()
        emoteTask?.cancel()
        extraEmotes = [:]
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        messages = []
        staged = []
        ready = []
        held = []
        waiting = []
        emotesLoaded = false
        pendingCount = 0
        paused = false
        channel = nil
        authenticated = false
        roomModes = []
        room = [:]
        pendingSends = []
    }

    private func run(_ channel: String) async {
        let ws = URLSession.shared.webSocketTask(with: URL(string: "wss://irc-ws.chat.twitch.tv:443")!)
        socket = ws
        ws.resume()
        let account = Account.shared
        var identity = ["PASS SCHMOOPIIE", "NICK justinfan\(Int.random(in: 10_000...99_999))"]
        if !authFailed, let token = account.token, let login = account.user?.login {
            identity = ["PASS oauth:\(token)", "NICK \(login)"]
        }
        authenticated = identity[0] != "PASS SCHMOOPIIE"
        room = [:]
        roomModes = []
        for line in ["CAP REQ :twitch.tv/tags twitch.tv/commands"] + identity + ["JOIN #\(channel)"] {
            try? await ws.send(.string(line))
        }
        while !Task.isCancelled {
            guard let message = try? await ws.receive() else { break }
            guard case .string(let text) = message else { continue }
            for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
                if line.hasPrefix("PING") {
                    try? await ws.send(.string("PONG :tmi.twitch.tv"))
                } else if let parsed = Self.parse(line) {
                    receive(parsed)
                } else {
                    control(line)
                }
            }
        }
        ws.cancel()
    }

    /// Solo para las capturas de CI: mete mensajes IRC de ejemplo en el chat.
    func injectForDemo(_ lines: [String]) {
        for line in lines {
            if let message = Self.parse(line) { receive(message) }
        }
    }

    // MARK: - Ritmo del chat

    /// Mensaje del directo recién llegado, todavía sin emotes de 7TV/BTTV/FFZ.
    private func receive(_ message: ChatMessage) {
        if emotesLoaded {
            stage(expand(message))
        } else {
            waiting.append((message: message, arrived: Date()))
        }
    }

    private func stage(_ message: ChatMessage) {
        EmoteImages.shared.prefetch(message.emoteURLs)
        staged.append((message: message, arrived: Date()))
    }

    private func startPump() {
        pump?.cancel()
        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.step()
            }
        }
    }

    private func step() {
        // Si la lista de emotes no llega en 3 s, el chat sigue sin ellos
        if !emotesLoaded, let first = waiting.first, first.arrived.timeIntervalSinceNow < -3 {
            markEmotesLoaded()
        }
        let images = EmoteImages.shared
        // Sale cuando sus emotes ya están; si una imagen tarda más de 1,2 s, sale igual para no atascar el chat
        while let first = staged.first,
              first.message.emoteURLs.allSatisfy({ images.isReady($0) }) || first.arrived.timeIntervalSinceNow < -1.2 {
            ready.append(first.message)
            staged.removeFirst()
        }
        guard !ready.isEmpty else { return }
        // Un quinto de lo pendiente cada 0,1 s: una ráfaga de 20 mensajes entra en ~0,5 s, sin saltos
        let count = max(1, ready.count / 5)
        let batch = ready.prefix(count)
        ready.removeFirst(count)
        if paused {
            held += batch
            if held.count > 300 { held.removeFirst(held.count - 300) }
            pendingCount = held.count
        } else {
            // Sin animación: con el chat desplazado, una animación movía lo que se estaba leyendo
            let now = Date()
            messages += batch.map { var message = $0; message.shownAt = now; return message }
            if messages.count > 200 { messages.removeFirst(messages.count - 200) }
        }
    }

    private func releaseHeld() {
        messages += held
        if messages.count > 200 { messages.removeFirst(messages.count - 200) }
        held = []
        pendingCount = 0
    }

    // MARK: - Mensajes

    private func message(from comment: Twitch.Comment) -> ChatMessage {
        let login = comment.commenter?.login ?? ""
        let parts: [ChatMessage.Part] = (comment.message?.fragments ?? []).map { fragment in
            if let id = fragment.emote?.emoteID {
                return .emote(url: Self.twitchEmoteURL(id), name: fragment.text ?? "")
            }
            return .text(fragment.text ?? "")
        }
        var message = ChatMessage(name: comment.commenter?.name ?? "?",
                                  color: Self.color(comment.message?.userColor.map { Substring($0) }, name: login),
                                  parts: Self.annotate(parts), isAction: false)
        // En los VOD Twitch guarda las suscripciones como texto normal: se reconocen por la frase
        let plain = (comment.message?.fragments ?? []).compactMap(\.text).joined()
        if plain.contains(" subscribed at Tier ") || plain.contains(" subscribed with Prime") {
            message.kind = .event(.init(style: .sub, text: plain))
            message.parts = []
        } else if plain.contains(" is gifting ") || plain.contains(" gifted a ") {
            message.kind = .event(.init(style: .gift, text: plain))
            message.parts = []
        }
        return expand(message)
    }

    /// Cambia las palabras que son emotes de 7TV/BTTV/FFZ por su imagen.
    private func expand(_ message: ChatMessage) -> ChatMessage {
        guard !extraEmotes.isEmpty else { return message }
        var parts: [ChatMessage.Part] = []
        var changed = false
        for part in message.parts {
            guard case .text(let text) = part else {
                parts.append(part)
                continue
            }
            var run = ""
            for (i, word) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                let separator = i == 0 ? "" : " "
                if let url = extraEmotes[String(word)] {
                    run += separator
                    if !run.isEmpty { parts.append(.text(run)) }
                    run = ""
                    parts.append(.emote(url: url, name: String(word)))
                    changed = true
                } else {
                    run += separator + word
                }
            }
            if !run.isEmpty { parts.append(.text(run)) }
        }
        guard changed else { return message }
        var copy = message
        copy.parts = parts
        return copy
    }

    nonisolated static func twitchEmoteURL(_ id: String) -> String {
        "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/default/dark/3.0"
    }

    // MARK: - IRC

    nonisolated static func splitTags(_ line: String) -> (tags: [Substring: Substring], rest: Substring) {
        var rest = Substring(line)
        var tags: [Substring: Substring] = [:]
        if rest.hasPrefix("@"), let space = rest.firstIndex(of: " ") {
            for pair in rest[rest.index(after: rest.startIndex)..<space].split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2 { tags[kv[0]] = kv[1] }
            }
            rest = rest[rest.index(after: space)...]
        }
        return (tags, rest)
    }

    nonisolated static func parse(_ line: String) -> ChatMessage? {
        let (tags, rest) = splitTags(line)
        let isNotice: Bool
        let afterChannel: Substring
        if let command = rest.range(of: " PRIVMSG #") {
            afterChannel = rest[command.upperBound...]
            isNotice = false
        } else if let command = rest.range(of: " USERNOTICE #") {
            afterChannel = rest[command.upperBound...]
            isNotice = true
        } else {
            return nil
        }
        // En un aviso (suscripción, raid…) el mensaje del usuario es opcional
        var text = afterChannel.range(of: " :").map { String(afterChannel[$0.upperBound...]) } ?? ""
        if !isNotice, text.isEmpty { return nil }
        let login = isNotice ? (tags["login"].map(String.init) ?? "") : String(rest.dropFirst().prefix { $0 != "!" })
        let display = tags["display-name"].map(String.init) ?? ""
        let name = display.isEmpty ? login : display

        var isAction = false
        if text.hasPrefix("\u{1}ACTION "), text.hasSuffix("\u{1}") {
            text = String(text.dropFirst(8).dropLast())
            isAction = true
        }

        var message = ChatMessage(name: name, color: color(tags["color"], name: login),
                                  parts: text.isEmpty ? [] : annotate(parts(text, emotes: tags["emotes"] ?? "")),
                                  isAction: isAction)
        message.ircID = tags["id"].map(String.init)
        message.login = login
        let msgID = tags["msg-id"].map(String.init) ?? ""
        if isNotice {
            // Una suscripción múltiple llega también regalo a regalo: basta con el aviso general
            if msgID == "subgift", tags["msg-param-community-gift-id"] != nil { return nil }
            var system = tags["system-msg"].map(unescape) ?? ""
            if msgID == "announcement" { system = "Anuncio" }
            guard !system.isEmpty else { return nil }
            message.kind = .event(.init(style: style(forNotice: msgID), text: system))
        } else if msgID == "highlighted-message" {
            message.kind = .highlighted
        } else if let bits = tags["bits"], let amount = Int(bits) {
            message.kind = .event(.init(style: .bits, text: "\(amount) bits"))
        }
        if let parent = tags["reply-parent-display-name"], let body = tags["reply-parent-msg-body"] {
            message.reply = "\(unescape(parent)): \(unescape(body))"
        }
        return message
    }

    nonisolated static func style(forNotice id: String) -> ChatMessage.Event.Style {
        switch id {
        case "sub", "resub", "primepaidupgrade", "giftpaidupgrade", "anongiftpaidupgrade": .sub
        case "subgift", "submysterygift", "anonsubgift", "anonsubmysterygift", "communitypayforward", "standardpayforward": .gift
        case "raid": .raid
        case "announcement": .announcement
        default: .other
        }
    }

    /// Valores de etiquetas IRC: "\s" es un espacio, "\:" un punto y coma…
    nonisolated static func unescape(_ value: Substring) -> String {
        var out = ""
        var chars = value.makeIterator()
        while let c = chars.next() {
            guard c == "\\" else {
                out.append(c)
                continue
            }
            switch chars.next() {
            case "s": out.append(" ")
            case ":": out.append(";")
            case "r", "n": out.append(" ")
            case let other?: out.append(other)
            case nil: break
            }
        }
        return out
    }

    /// Separa en el texto las menciones (@nombre) y los enlaces.
    nonisolated static func annotate(_ parts: [ChatMessage.Part]) -> [ChatMessage.Part] {
        var out: [ChatMessage.Part] = []
        for part in parts {
            guard case .text(let text) = part else {
                out.append(part)
                continue
            }
            var run = ""
            for (i, word) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                if i > 0 { run += " " }
                let token = String(word)
                if token.count > 1, token.hasPrefix("@") {
                    if !run.isEmpty { out.append(.text(run)) }
                    run = ""
                    out.append(.mention(token))
                } else if let url = linkURL(token) {
                    if !run.isEmpty { out.append(.text(run)) }
                    run = ""
                    out.append(.link(token, url))
                } else {
                    run += token
                }
            }
            if !run.isEmpty { out.append(.text(run)) }
        }
        return out
    }

    nonisolated static func linkURL(_ token: String) -> URL? {
        guard token.count > 4, token.contains("."), let detector = linkDetector else { return nil }
        let range = NSRange(token.startIndex..., in: token)
        // Tiene que ser la palabra entera (sin contar un signo al final), no "hola.que"
        guard let match = detector.firstMatch(in: token, range: range),
              match.range.location == 0, match.range.length >= range.length - 1 else { return nil }
        return match.url
    }

    /// "25:0-4,12-16/1902:6-10" → trozos de texto y emotes (posiciones en escalares Unicode).
    nonisolated static func parts(_ text: String, emotes: Substring) -> [ChatMessage.Part] {
        var ranges: [(start: Int, end: Int, id: String)] = []
        for spec in emotes.split(separator: "/") {
            let pieces = spec.split(separator: ":")
            guard pieces.count == 2 else { continue }
            for r in pieces[1].split(separator: ",") {
                let bounds = r.split(separator: "-")
                if bounds.count == 2, let s = Int(bounds[0]), let e = Int(bounds[1]) {
                    ranges.append((s, e, String(pieces[0])))
                }
            }
        }
        guard !ranges.isEmpty else { return [.text(text)] }
        let scalars = Array(text.unicodeScalars)
        func string(_ slice: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(slice)) }
        var parts: [ChatMessage.Part] = []
        var cursor = 0
        for r in ranges.sorted(by: { $0.start < $1.start }) where r.start >= cursor && r.start <= r.end && r.end < scalars.count {
            if r.start > cursor { parts.append(.text(string(scalars[cursor..<r.start]))) }
            parts.append(.emote(url: twitchEmoteURL(r.id), name: string(scalars[r.start...r.end])))
            cursor = r.end + 1
        }
        if cursor < scalars.count { parts.append(.text(string(scalars[cursor...]))) }
        return parts
    }

    /// Color del nombre, aclarado si es demasiado oscuro para leerse sobre negro.
    nonisolated static func color(_ hex: Substring?, name: String) -> Color {
        var rgb: (Double, Double, Double)
        if let hex, hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) {
            rgb = (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
        } else {
            let palette: [(Double, Double, Double)] = [(0.98, 0.45, 0.45), (0.45, 0.75, 1), (0.55, 0.9, 0.55),
                                                       (1, 0.75, 0.35), (0.8, 0.6, 1), (0.4, 0.9, 0.85), (1, 0.55, 0.8)]
            rgb = palette[Int(name.unicodeScalars.reduce(0) { $0 &+ $1.value }) % palette.count]
        }
        let luminance = 0.299 * rgb.0 + 0.587 * rgb.1 + 0.114 * rgb.2
        if luminance < 0.45 {
            rgb = ((rgb.0 + 1) / 2, (rgb.1 + 1) / 2, (rgb.2 + 1) / 2)
        }
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

/// Imágenes de emotes (Twitch, 7TV, BTTV, FFZ), descargadas una vez y compartidas.
/// Las animadas guardan todos sus fotogramas con su duración. No avisa a las vistas
/// al terminar una descarga: el chat solo muestra mensajes con sus emotes ya listos,
/// así una imagen nueva no redibuja (ni mueve) los mensajes que ya están en pantalla.
@MainActor
final class EmoteImages {
    struct Frames {
        let images: [UIImage]
        /// Momento en que acaba cada fotograma, acumulado.
        let ends: [Double]
        var isAnimated: Bool { images.count > 1 }

        func frame(at time: TimeInterval) -> UIImage {
            guard isAnimated, let total = ends.last, total > 0 else { return images[0] }
            let t = time.truncatingRemainder(dividingBy: total)
            return images[ends.firstIndex { t < $0 } ?? images.count - 1]
        }
    }

    static let shared = EmoteImages()
    private var cache: [String: Frames] = [:]
    private var failed: Set<String> = []
    private var loading: Set<String> = []

    /// Fotograma que toca en `time` (el primero si no se pasa hora).
    func image(_ url: String, at time: Date? = nil) -> UIImage? {
        guard let frames = cache[url] else { return nil }
        return time.map { frames.frame(at: $0.timeIntervalSinceReferenceDate) } ?? frames.images[0]
    }

    func isAnimated(_ url: String) -> Bool { cache[url]?.isAnimated ?? false }

    /// Descargada, o falló (entonces se muestra su nombre).
    func isReady(_ url: String) -> Bool { cache[url] != nil || failed.contains(url) }

    func prefetch(_ urls: [String]) {
        for url in urls where !isReady(url) && loading.insert(url).inserted {
            Task { await load(url) }
        }
    }

    /// Espera a tener la imagen, para las vistas que sí quieren enterarse (el selector de emotes).
    func loaded(_ url: String) async -> UIImage? {
        if !isReady(url) {
            if loading.insert(url).inserted {
                await load(url)
            } else {
                // Ya la está bajando otro: se espera a que acabe
                while loading.contains(url), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(80)) }
            }
        }
        return image(url)
    }

    private func load(_ link: String) async {
        defer { loading.remove(link) }
        guard let url = URL(string: link), let data = try? await URLSession.shared.data(from: url).0 else {
            failed.insert(link)
            return
        }
        // Decodificar fuera del hilo principal: un emote animado tiene decenas de fotogramas
        let frames = await Task.detached(priority: .userInitiated) { Self.decode(data) }.value
        if let frames { cache[link] = frames } else { failed.insert(link) }
    }

    nonisolated private static func decode(_ data: Data) -> Frames? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        guard let first = CGImageSourceCreateImageAtIndex(source, 0, nil), first.height > 0 else { return nil }
        // Todos los fotogramas se redibujan a la altura de una línea (22 pt) y con el mismo
        // tamaño: antes cada uno salía a su tamaño original (los pequeños se veían pixelados
        // o más chicos, y si un fotograma medía distinto el emote saltaba o pisaba el texto)
        let canvas = canvasSize(source) ?? CGSize(width: first.width, height: first.height)
        let size = CGSize(width: (Self.lineHeight * canvas.width / canvas.height).rounded(), height: Self.lineHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        // Como mucho ~100 fotogramas: los emotes largos se muestrean sin cambiar su velocidad
        let step = max(1, count / 100)
        var images: [UIImage] = []
        var ends: [Double] = []
        var elapsed = 0.0
        for index in stride(from: 0, to: count, by: step) {
            guard let frame = index == 0 ? first : CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            images.append(renderer.image { _ in
                UIImage(cgImage: frame).draw(in: CGRect(origin: .zero, size: size))
            })
            elapsed += delay(source, index) * Double(step)
            ends.append(elapsed)
        }
        return images.isEmpty ? nil : Frames(images: images, ends: ends)
    }

    nonisolated private static let lineHeight: CGFloat = 22

    /// Tamaño de la animación entera (puede ser mayor que el de un fotograma suelto).
    nonisolated private static func canvasSize(_ source: CGImageSource) -> CGSize? {
        let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let pairs: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPCanvasPixelWidth, kCGImagePropertyWebPCanvasPixelHeight),
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFCanvasPixelWidth, kCGImagePropertyGIFCanvasPixelHeight),
        ]
        for (dict, w, h) in pairs {
            if let d = props?[dict] as? [CFString: Any], let width = d[w] as? Double, let height = d[h] as? Double,
               width > 0, height > 0 {
                return CGSize(width: width, height: height)
            }
        }
        return nil
    }

    /// Duración de un fotograma de GIF o WebP animado (0,1 s si no la indica o es absurda).
    nonisolated private static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        var value: Double?
        if let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            value = (gif[kCGImagePropertyGIFUnclampedDelayTime] ?? gif[kCGImagePropertyGIFDelayTime]) as? Double
        } else if let webp = props?[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            value = (webp[kCGImagePropertyWebPUnclampedDelayTime] ?? webp[kCGImagePropertyWebPDelayTime]) as? Double
        }
        guard let value, value >= 0.02 else { return 0.1 }
        return value
    }
}
