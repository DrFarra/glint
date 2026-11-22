import WebKit

/// Acciones de la cuenta que Twitch protege con su antibots (seguir, canjear y reclamar puntos).
///
/// Su API solo las acepta con un token de "integridad" que firma el script de su propia web:
/// pedido desde la app, Twitch lo da pero lo marca como no válido. Así que se hacen desde una
/// página de twitch.tv invisible, con la sesión del usuario, para que sea su web quien lo firme.
@MainActor
enum TwitchBridge {
    private static var view: WKWebView?
    private static var loading: Task<Void, Never>?

    /// Lanza una mutación GraphQL como la web y devuelve su `data`. Error si Twitch la rechaza.
    static func mutate(_ query: String, _ variables: [String: Any], token: String) async throws -> [String: Any] {
        let view = await page()
        let script = """
            const dev = (document.cookie.match(/(?:^|; )unique_id=([^;]+)/) || [])[1] || '';
            const headers = { 'Client-Id': clientID, 'Authorization': 'OAuth ' + token, 'X-Device-Id': dev };
            const integrity = await (await fetch('https://gql.twitch.tv/integrity', { method: 'POST', headers })).json();
            const response = await fetch('https://gql.twitch.tv/gql', {
                method: 'POST',
                headers: { ...headers, 'Client-Integrity': integrity.token || '' },
                body: JSON.stringify({ query, variables })
            });
            return await response.text();
            """
        // En el mundo de la página: así pasa por el fetch que el antibots de Twitch ha preparado
        let text = try await view.callAsyncJavaScript(
            script, arguments: ["query": query, "variables": variables, "token": token, "clientID": Twitch.clientID],
            contentWorld: .page) as? String
        guard let data = text?.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Twitch.Failure(message: "Twitch no respondió")
        }
        if let errors = json["errors"] as? [[String: Any]], let message = errors.first?["message"] as? String {
            throw Twitch.Failure(message: message == "failed integrity check" ? "Twitch no lo permitió desde la app" : message)
        }
        return json["data"] as? [String: Any] ?? [:]
    }

    /// Tus seguidos como los ve la web: se abre su página "Siguiendo" en una web invisible y se leen
    /// las respuestas de su propia API (a la app, a algunas cuentas Twitch se los da vacíos).
    /// No se lee el HTML: solo el JSON que pide la página, que cambia mucho menos.
    static func followedChannels(token: String) async throws -> [ChannelRef] {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = .all
        // Antes de que cargue la página: guarda cada respuesta de su API que traiga "follows"
        config.userContentController.addUserScript(WKUserScript(source: """
            (() => {
                window.__glintFollows = [];
                window.__glintOps = [];
                const keep = t => {
                    if (typeof t !== 'string') return;
                    if (t.includes('"follows"')) window.__glintFollows.push(t);
                    // Nombre de cada consulta de la página, para el aviso si no aparece la lista
                    try { [].concat(JSON.parse(t)).forEach(r => r && r.extensions && window.__glintOps.push(r.extensions.operationName)); } catch (e) {}
                };
                const originalFetch = window.fetch;
                window.fetch = async function (...args) {
                    const response = await originalFetch.apply(this, args);
                    try {
                        const url = String((args[0] && args[0].url) || args[0]);
                        if (url.includes('gql.twitch.tv')) response.clone().text().then(keep);
                    } catch (e) {}
                    return response;
                };
                // Por si la página pide su API con XMLHttpRequest en vez de fetch
                const originalOpen = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function (method, url, ...rest) {
                    if (String(url).includes('gql.twitch.tv')) this.addEventListener('load', () => keep(this.responseText));
                    return originalOpen.call(this, method, url, ...rest);
                };
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        // Tu sesión en la web (normalmente ya está, de cuando iniciaste sesión)
        if let cookie = HTTPCookie(properties: [.domain: ".twitch.tv", .path: "/", .name: "auth-token", .value: token,
                                                .secure: "TRUE", .expires: Date(timeIntervalSinceNow: 30 * 86_400)]) {
            await config.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        // Fuera de pantalla la web de Twitch no pide la lista (solo carga lo que se dibuja): va detrás
        // de la app, a tamaño completo y sin recibir toques, así que se dibuja pero no se ve
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) {
            view.frame = window.bounds
            view.isUserInteractionEnabled = false
            window.insertSubview(view, at: 0)
        }
        defer { view.removeFromSuperview() }
        view.load(URLRequest(url: URL(string: "https://www.twitch.tv/directory/following/channels")!))

        // Hasta 20 s; se bajan todas las zonas con scroll para que pida más, hasta que la lista deje de crecer
        var seen = 0
        var quiet = 0
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(500))
            _ = try? await view.evaluateJavaScript("""
                document.querySelectorAll('*').forEach(e => { if (e.scrollHeight > e.clientHeight + 50) e.scrollTop = e.scrollHeight; });
                window.scrollTo(0, document.body.scrollHeight); 0
                """)
            let count = (try? await view.evaluateJavaScript("window.__glintFollows.length")) as? Int ?? 0
            guard count > 0 else { continue }
            quiet = count == seen ? quiet + 1 : 0
            seen = count
            if quiet >= 4 { break }
        }
        let texts = (try? await view.evaluateJavaScript("window.__glintFollows")) as? [String] ?? []
        if texts.isEmpty {
            let ops = (try? await view.evaluateJavaScript("window.__glintOps.filter(Boolean)")) as? [String] ?? []
            throw Twitch.Failure(message: ops.isEmpty ? "la página no pidió nada a su API"
                                 : "sin seguidos en \(ops.count) respuestas (\(Set(ops).sorted().joined(separator: ", ")))")
        }
        var out: [ChannelRef] = []
        for text in texts {
            if let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
                collectFollows(json, into: &out)
            }
        }
        var unique = Set<String>()
        return out.filter { unique.insert($0.login).inserted }
    }

    /// Busca en la respuesta cualquier `follows { edges { node { login … } } }`, esté donde esté.
    private static func collectFollows(_ json: Any, into out: inout [ChannelRef]) {
        if let dict = json as? [String: Any] {
            if let edges = (dict["follows"] as? [String: Any])?["edges"] as? [[String: Any]] {
                for case let node as [String: Any] in edges.compactMap({ $0["node"] }) {
                    guard let login = node["login"] as? String else { continue }
                    out.append(ChannelRef(login: login, displayName: node["displayName"] as? String ?? login,
                                          avatar: node["profileImageURL"] as? String))
                }
            }
            for value in dict.values { collectFollows(value, into: &out) }
        } else if let array = json as? [Any] {
            for value in array { collectFollows(value, into: &out) }
        }
    }

    /// La página se carga una vez y se queda viva mientras la app esté abierta.
    private static func page() async -> WKWebView {
        if let view, loading == nil { return view }
        if loading == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            config.mediaTypesRequiringUserActionForPlayback = .all
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
            view.load(URLRequest(url: URL(string: "https://www.twitch.tv/directory")!))
            self.view = view
            loading = Task {
                // Hasta que su antibots (KPSDK) esté listo, como mucho 15 s
                for _ in 0..<60 {
                    try? await Task.sleep(for: .milliseconds(250))
                    if !view.isLoading,
                       (try? await view.evaluateJavaScript(
                           "typeof window.KPSDK !== 'undefined' && (typeof KPSDK.isReady !== 'function' || KPSDK.isReady())")) as? Bool == true {
                        break
                    }
                }
            }
        }
        await loading?.value
        loading = nil
        return view!
    }
}
