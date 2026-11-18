import Foundation
import Observation
import Security
import WebKit

/// Sesión de Twitch. Se inicia en la propia web de Twitch dentro de la app: el usuario
/// escribe su contraseña en la página de Twitch (la app nunca la ve) y la app se queda
/// con el token de esa sesión, guardado en el llavero del iPhone.
///
/// Con él se escribe en el chat y se leen tus seguidos, emotes y puntos. Seguir canales,
/// canjear puntos o votar en predicciones Twitch solo lo deja hacer desde su web
/// (las llamadas directas fallan su control antibots), así que eso se hace en su página.
@MainActor @Observable
final class Account {
    struct User: Codable, Equatable {
        let id: String
        let login: String
        let displayName: String
        let profileImageURL: String?
    }

    struct Emote: Identifiable, Hashable {
        let id: String
        let token: String
        var url: String { ChatClient.twitchEmoteURL(id) }
    }

    struct EmoteSet: Identifiable {
        let id: String
        let owner: String
        let emotes: [Emote]
    }

    static let shared = Account()

    private(set) var user: User? = Account.savedUser()
    private(set) var emoteSets: [EmoteSet] = []
    @ObservationIgnored private(set) var token: String? = Keychain.read()
    /// Emotes de Twitch del usuario por nombre, para mostrar bien sus propios mensajes.
    @ObservationIgnored private(set) var emoteIDs: [String: String] = [:]

    var isLoggedIn: Bool { user != nil && token != nil }

    /// Con el token de la web de Twitch: comprueba de quién es y guarda la sesión.
    func signIn(token: String) async throws {
        guard let user = try await Twitch.currentUser(token: token) else {
            throw Twitch.Failure(message: "Twitch no aceptó la sesión. Prueba otra vez.")
        }
        Keychain.save(token)
        self.token = token
        setUser(user)
    }

    func signOut() async {
        Keychain.delete()
        token = nil
        setUser(nil)
        emoteSets = []
        emoteIDs = [:]
        // También se cierra la sesión de la web de Twitch dentro de la app
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                               for: records.filter { $0.displayName.contains("twitch") || $0.displayName.contains("ttvnw") })
    }

    /// Al abrir la app: datos del perfil al día. Si Twitch ya no acepta el token
    /// (cerraste sesión en otro sitio o caducó), se cierra la sesión aquí también.
    func refresh() async {
        guard let token else { return }
        do {
            if let user = try await Twitch.currentUser(token: token) {
                setUser(user)
            } else {
                await signOut()
            }
        } catch {
            // Sin conexión: se mantiene la sesión
        }
    }

    func loadEmotes() async {
        guard emoteSets.isEmpty, let token, let sets = try? await Twitch.emoteSets(token: token) else { return }
        emoteSets = sets
        emoteIDs = Dictionary(sets.flatMap(\.emotes).map { ($0.token, $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    private func setUser(_ user: User?) {
        self.user = user
        UserDefaults.standard.set(user.flatMap { try? JSONEncoder().encode($0) }, forKey: "twitchUser")
    }

    private static func savedUser() -> User? {
        guard Keychain.read() != nil, let data = UserDefaults.standard.data(forKey: "twitchUser") else { return nil }
        return try? JSONDecoder().decode(User.self, from: data)
    }
}

/// El token de Twitch en el llavero, solo accesible con el iPhone desbloqueado al menos una vez.
enum Keychain {
    private static let base: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.emilio.glint",
        kSecAttrAccount: "twitch-token",
    ]

    static func read() -> String? {
        var query = base
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) {
        delete()
        var item = base
        item[kSecValueData] = Data(value.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}
