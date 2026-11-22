import Foundation
import Observation

/// Canal guardado en el iPhone (seguidos e historial de búsqueda).
struct ChannelRef: Codable, Hashable, Identifiable {
    let login: String
    var displayName: String
    var avatar: String?
    var id: String { login }
}

/// VOD visto, con el punto donde lo dejaste.
struct WatchedVideo: Codable, Identifiable {
    let id: String
    var title: String
    var thumbnail: String?
    var channel: String
    var length: Double
    var position: Double
    var date: Date

    var progress: Double { length > 0 ? min(1, position / length) : 0 }
    /// Se reanuda salvo que estuviera casi al final.
    var resumePosition: Double? { position > 10 && position < length - 60 ? position : nil }
}

/// Cofre de puntos reclamado solo (o el intento fallido, con su motivo).
struct BonusClaim: Codable, Identifiable {
    var id = UUID()
    let channel: String
    let date: Date
    /// Lo que subió el saldo al reclamar; nil si no se pudo saber.
    let gained: Int?
    /// nil si salió bien.
    let error: String?
}

extension Twitch.Channel {
    var ref: ChannelRef { ChannelRef(login: login, displayName: name, avatar: profileImageURL) }
}

/// Seguidos e historial, guardados en el iPhone: no hace falta cuenta de Twitch.
@MainActor @Observable
final class Library {
    private(set) var follows: [ChannelRef] = Library.load("follows") { didSet { Library.save(follows, "follows") } }
    private(set) var recents: [ChannelRef] = Library.load("recentSearches") { didSet { Library.save(recents, "recentSearches") } }
    private(set) var watched: [WatchedVideo] = Library.load("watchedVideos") { didSet { Library.save(watched, "watchedVideos") } }
    private(set) var claims: [BonusClaim] = Library.load("bonusClaims") { didSet { Library.save(claims, "bonusClaims") } }

    /// Lo más reciente primero; se guardan los últimos 200.
    func recordClaim(_ claim: BonusClaim) {
        claims.insert(claim, at: 0)
        if claims.count > 200 { claims.removeLast(claims.count - 200) }
    }

    func clearClaims() { claims = [] }

    func isFollowing(_ login: String) -> Bool { follows.contains { $0.login == login } }

    func toggleFollow(_ channel: ChannelRef) {
        if isFollowing(channel.login) {
            follows.removeAll { $0.login == channel.login }
        } else {
            follows.insert(channel, at: 0)
        }
    }

    func setFollow(_ channel: ChannelRef, _ follow: Bool) {
        if follow != isFollowing(channel.login) { toggleFollow(channel) }
    }

    /// Añade los seguidos de la cuenta de Twitch que aún no estén (no quita ninguno).
    /// Van arriba, como los que sigues desde la app: al final pasaban desapercibidos.
    func importFollows(_ channels: [ChannelRef]) {
        let new = channels.filter { !isFollowing($0.login) }
        if !new.isEmpty { follows = new + follows }
    }

    /// Trae los seguidos de tu cuenta de Twitch (al abrir la app, al volver a ella y al recargar Inicio).
    func importFollows(token: String) async {
        let (channels, tried) = await Twitch.followedChannels(token: token, userID: Account.shared.user?.id)
        importFollows(channels)
        // Si no llega nada, en Inicio se ve qué pasó con cada forma de pedirlos
        followsProblem = channels.isEmpty ? "No llegaron tus seguidos de Twitch (\(tried.joined(separator: "; ")))." : nil
    }

    /// Por qué no llegaron los seguidos de la cuenta (se enseña en Inicio).
    private(set) var followsProblem: String?

    func addRecent(_ channel: ChannelRef) {
        recents.removeAll { $0.login == channel.login }
        recents.insert(channel, at: 0)
        if recents.count > 25 { recents.removeLast(recents.count - 25) }
    }

    func removeRecent(_ login: String) { recents.removeAll { $0.login == login } }
    func clearRecents() { recents = [] }

    func watched(_ id: String) -> WatchedVideo? { watched.first { $0.id == id } }

    /// Lo más reciente primero; se guardan los últimos 100.
    func recordWatch(_ video: Twitch.Video, position: Double) {
        let entry = WatchedVideo(id: video.id, title: video.title ?? "", thumbnail: video.previewThumbnailURL,
                                 channel: video.owner?.name ?? "", length: Double(video.lengthSeconds ?? 0),
                                 position: position, date: .now)
        watched.removeAll { $0.id == video.id }
        watched.insert(entry, at: 0)
        if watched.count > 100 { watched.removeLast(watched.count - 100) }
    }

    func removeWatched(_ id: String) { watched.removeAll { $0.id == id } }
    func clearWatched() { watched = [] }

    private static func load<T: Decodable>(_ key: String) -> [T] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private static func save<T: Encodable>(_ value: [T], _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

/// Pestaña elegida y la pila de navegación de cada una, para poder abrir un
/// canal desde el reproductor.
@MainActor @Observable
final class Router {
    enum Tab: Hashable { case home, browse, search }
    var tab: Tab = .home
    var home: [Route] = []
    var browse: [Route] = []
    var search: [Route] = []
    var showAccount = false
    /// Solo para las capturas: abrir la cuenta directamente en la página de inicio de sesión.
    var accountAtLogin = false

    func open(_ route: Route) {
        switch tab {
        case .home: home.append(route)
        case .browse: browse.append(route)
        case .search: search.append(route)
        }
    }
}

enum Route: Hashable {
    case channel(String)
    case game(String)
    case history
}
