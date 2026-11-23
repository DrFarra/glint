import Observation
import SwiftUI

/// Lo que se está viendo: carga la información del canal o del vídeo, arranca
/// el reproductor y el chat, y sabe si el reproductor está minimizado.
@MainActor @Observable
final class Playback {
    enum Media: Equatable {
        case live(String)
        case video(String)
        case clip(String)
    }

    private(set) var media: Media?
    var minimized = false
    private(set) var channel: Twitch.Channel?
    private(set) var video: Twitch.Video?
    private(set) var clip: Twitch.Clip?
    /// Otras emisiones del canal, debajo de un vídeo.
    private(set) var moreVideos: [Twitch.Video] = []
    private(set) var problem: String?
    /// Campañas de drops activas en el directo que se está viendo.
    private(set) var liveDrops: [String] = []
    /// Encima del chat del directo: el mensaje fijado y la predicción en curso.
    private(set) var pinnedMessage: String?
    private(set) var prediction: Twitch.Prediction?
    let engine = PlayerEngine()
    let chat = ChatClient()
    /// Para el historial de vídeos vistos; lo asigna la vista raíz.
    @ObservationIgnored var library: Library?

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Segundo en el que empezar el próximo VOD (al abrir la emisión de un clip).
    @ObservationIgnored private var startAt: Double?

    var login: String? {
        switch media {
        case .live(let login): login
        case .video: video?.owner?.login
        case .clip: clip?.broadcaster?.login
        case nil: nil
        }
    }

    func play(_ media: Media, at offset: Double? = nil) {
        startAt = offset
        if self.media == media, offset == nil {
            withAnimation(.snappy) { minimized = false }
            return
        }
        stop()
        problem = nil
        withAnimation(.snappy) {
            self.media = media
            minimized = false
        }
        task = Task { await start(media) }
    }

    func close() {
        stop()
        withAnimation(.snappy) { media = nil }
    }

    func retry() {
        guard let media else { return }
        if engine.error != nil, problem == nil {
            engine.retry()
        } else {
            stop()
            problem = nil
            self.media = media
            task = Task { await start(media) }
        }
    }

    private func stop() {
        saveProgress()
        task?.cancel()
        engine.stop()
        chat.disconnect()
        channel = nil
        video = nil
        clip = nil
        moreVideos = []
        liveDrops = []
        pinnedMessage = nil
        prediction = nil
    }

    private func saveProgress() {
        guard case .video = media, let video, engine.position > 0 else { return }
        library?.recordWatch(video, position: engine.position)
    }

    /// Qué pasó la última vez con los puntos del directo (se ve en Ajustes › Puntos del canal).
    private(set) var pointsStatus: String?

    /// Cada minuto, mientras ves un directo con tu cuenta: le dice a Twitch que lo estás viendo (sin
    /// eso no hay puntos por ver ni cofres) y, si hay cofre, lo reclama como un clic tuyo. Espera
    /// unos segundos al azar: reclamar al instante y siempre igual es lo que delata a un bot.
    private func watchAndClaim(_ login: String) async {
        let channelName = channel?.name ?? login
        var status = [Date.now.formatted(date: .omitted, time: .shortened), channelName]
        defer { pointsStatus = status.joined(separator: " · ") }
        guard let token = Account.shared.token, let userID = Account.shared.user?.id else {
            status.append("sin sesión: no cuenta")
            return
        }
        guard engine.isPlaying else {
            status.append("vídeo en pausa: no cuenta")
            return
        }
        if let channelID = channel?.userID, let broadcastID = channel?.stream?.id {
            do {
                try await Twitch.reportWatching(login: login, channelID: channelID, broadcastID: broadcastID,
                                                userID: userID, token: token)
                status.append("Twitch sabe que lo ves")
            } catch {
                status.append("aviso de que lo ves falló: \(error.localizedDescription)")
            }
        }
        guard UserDefaults.standard.object(forKey: "autoClaimBonus") as? Bool ?? true else { return }
        let points: Twitch.Points
        do {
            points = try await Twitch.points(login, token: token)
        } catch {
            status.append("puntos: \(error.localizedDescription)")
            return
        }
        // Exacto, no "3,9 mil": así se ve subir de 10 en 10 y se sabe si Twitch te cuenta como espectador
        status.append("saldo \(points.balance.map { $0.formatted() } ?? "?")")
        guard let claimID = points.claimID else {
            status.append("sin cofre")
            return
        }
        try? await Task.sleep(for: .seconds(Double.random(in: 4...40)))
        guard !Task.isCancelled, engine.isPlaying else { return }
        do {
            try await Twitch.claimBonus(channelID: points.channelID, claimID: claimID, token: token)
            status.append("cofre reclamado")
            chat.notice("Cofre de \(points.name ?? "puntos") reclamado automáticamente.")
            // Aproximado: el saldo también sube solo por ver el directo
            let after = await Twitch.pointsBalance(login, token: token)
            let gained = after.flatMap { a in points.balance.map { a - $0 } }.flatMap { $0 > 0 ? $0 : nil }
            library?.recordClaim(BonusClaim(channel: channelName, date: .now, gained: gained, error: nil))
        } catch {
            status.append("cofre: \(error.localizedDescription)")
            chat.notice("No se pudo reclamar el cofre de puntos: \(error.localizedDescription)")
            library?.recordClaim(BonusClaim(channel: channelName, date: .now, gained: nil, error: error.localizedDescription))
        }
    }

    private func start(_ media: Media) async {
        do {
            switch media {
            case .live(let login):
                chat.connect(login)
                guard let channel = try await Twitch.channel(login) else {
                    problem = "Este canal no existe"
                    return
                }
                self.channel = channel
                chat.loadEmotes(channelID: channel.userID)
                guard let stream = channel.stream else {
                    problem = "\(channel.name) no está en directo ahora"
                    return
                }
                engine.startLive(login: login, startedAt: stream.createdAt, archiveID: stream.archiveVideo?.id)
                liveDrops = await Twitch.channelDrops(login)
                (pinnedMessage, prediction) = await Twitch.chatExtras(login)
                // Espectadores, título y categoría al día
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(60))
                    if let fresh = try? await Twitch.channel(login), fresh.stream != nil {
                        self.channel = fresh
                        engine.updateArchive(fresh.stream?.archiveVideo?.id)
                    }
                    (pinnedMessage, prediction) = await Twitch.chatExtras(login)
                    await watchAndClaim(login)
                }
            case .video(let id):
                guard let video = try await Twitch.video(id) else {
                    problem = "Este vídeo ya no existe"
                    return
                }
                self.video = video
                let resume = startAt ?? library?.watched(id)?.resumePosition
                startAt = nil
                engine.startVOD(id: id, length: Double(video.lengthSeconds ?? 0), at: resume)
                library?.recordWatch(video, position: resume ?? 0)
                chat.replay(videoID: id) { [weak engine] in engine?.position ?? 0 }
                chat.loadEmotes(channelID: video.owner?.userID)
                if let login = video.owner?.login, let owner = try? await Twitch.channel(login, withVideos: true) {
                    moreVideos = (owner.videos?.nodes ?? []).filter { $0.id != id }
                }
                // Guarda por dónde vas, por si la app se cierra de golpe
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(10))
                    saveProgress()
                }
            case .clip(let slug):
                guard let clip = try await Twitch.clip(slug) else {
                    problem = "Este clip ya no existe"
                    return
                }
                self.clip = clip
                engine.startClip(slug: slug, length: Double(clip.durationSeconds ?? 0))
            }
        } catch is CancellationError {
        } catch {
            problem = error.localizedDescription
        }
    }
}
