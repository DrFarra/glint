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
    }

    private func saveProgress() {
        guard case .video = media, let video, engine.position > 0 else { return }
        library?.recordWatch(video, position: engine.position)
    }

    /// Cofre de puntos del canal: se reclama solo, como un clic tuyo y solo mientras lo ves.
    /// Espera unos segundos al azar: reclamar al instante y siempre igual es lo que delata a un bot.
    private func claimBonus(_ login: String) async {
        guard UserDefaults.standard.object(forKey: "autoClaimBonus") as? Bool ?? true, engine.isPlaying,
              let token = Account.shared.token,
              let points = try? await Twitch.points(login, token: token), let claimID = points.claimID else { return }
        try? await Task.sleep(for: .seconds(Double.random(in: 4...40)))
        guard !Task.isCancelled, engine.isPlaying else { return }
        let channelName = channel?.name ?? login
        do {
            try await Twitch.claimBonus(channelID: points.channelID, claimID: claimID, token: token)
            chat.notice("Cofre de \(points.name ?? "puntos") reclamado automáticamente.")
            // Aproximado: el saldo también sube solo por ver el directo
            let after = await Twitch.pointsBalance(login, token: token)
            let gained = after.flatMap { a in points.balance.map { a - $0 } }.flatMap { $0 > 0 ? $0 : nil }
            library?.recordClaim(BonusClaim(channel: channelName, date: .now, gained: gained, error: nil))
        } catch {
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
                // Espectadores, título y categoría al día
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(60))
                    if let fresh = try? await Twitch.channel(login), fresh.stream != nil {
                        self.channel = fresh
                        engine.updateArchive(fresh.stream?.archiveVideo?.id)
                    }
                    await claimBonus(login)
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
