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
