import AVFoundation

/// Devuelve el audio original a los tramos silenciados de un VOD cuando Twitch aún lo guarda.
///
/// AVPlayer pide las listas HLS a este delegado (con un esquema propio) y en cada trozo
/// "N-muted" se pone el original si sigue en el servidor: según el VOD y la calidad, Twitch
/// lo deja como "N" o como "N-unmuted", o ya lo ha borrado y entonces se queda silenciado.
final class Unmuter: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "glint-unmute"
    let queue = DispatchQueue(label: "glint.unmute")
    /// Recibe los tramos que siguen silenciados en cada lista de calidad que se carga.
    private let onMuted: ([Range<Double>]) -> Void
    /// Listas ya reescritas (AVPlayer vuelve a pedirlas al cambiar de calidad). Solo se toca en `queue`.
    private var cache: [URL: Data] = [:]

    init(onMuted: @escaping ([Range<Double>]) -> Void) {
        self.onMuted = onMuted
    }

    func asset(_ url: URL) -> AVURLAsset {
        let asset = AVURLAsset(url: Self.swapScheme(url, to: Self.scheme))
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let fake = request.request.url, fake.scheme == Self.scheme else { return false }
        let url = Self.swapScheme(fake, to: "https")
        if let data = cache[url] {
            Self.respond(request, data)
            return true
        }
        Task {
            do {
                let data = try await rewrite(url)
                queue.async {
                    self.cache[url] = data
                    Self.respond(request, data)
                }
            } catch {
                queue.async { if !request.isCancelled { request.finishLoading(with: error) } }
            }
        }
        return true
    }

    private static func respond(_ request: AVAssetResourceLoadingRequest, _ data: Data) {
        guard !request.isCancelled else { return }
        request.dataRequest?.respond(with: data)
        request.finishLoading()
    }

    private func rewrite(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard code == 200 else { throw Twitch.Failure(message: "Twitch respondió con un error (\(code))") }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let isMaster = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF") }

        // Con el esquema propio las direcciones relativas no se resolverían: todo va absoluto.
        // Las listas de cada calidad vuelven a pasar por aquí; los trozos de vídeo van directos a Twitch.
        func absolute(_ path: String) -> String {
            guard let resolved = URL(string: path, relativeTo: url)?.absoluteURL else { return path }
            return (isMaster ? Self.swapScheme(resolved, to: Self.scheme) : resolved).absoluteString
        }

        var muted: [(line: Int, url: URL, time: Range<Double>)] = []
        var time = 0.0
        var length = 0.0
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("#EXTINF:") {
                length = Double(line.dropFirst(8).prefix { $0 != "," }) ?? 0
            } else if line.hasPrefix("#"), let r = line.range(of: "URI=\""),
                      let end = line[r.upperBound...].firstIndex(of: "\"") {
                lines[i] = line.replacingCharacters(in: r.upperBound..<end, with: absolute(String(line[r.upperBound..<end])))
            } else if !line.hasPrefix("#"), !line.isEmpty {
                lines[i] = absolute(line)
                if !isMaster, line.contains("-muted."), let segment = URL(string: lines[i]) {
                    muted.append((i, segment, time..<time + length))
                }
                time += length
            }
        }
        guard !isMaster else { return Data(lines.joined(separator: "\n").utf8) }

        // Una petición pequeña por trozo silenciado, varias a la vez (con ~450 trozos son unos segundos)
        let originals = await withTaskGroup(of: (Int, URL?).self, returning: [Int: URL].self) { group in
            var found: [Int: URL] = [:]
            for (n, segment) in muted.enumerated() {
                if n >= 32, let done = await group.next() { found[done.0] = done.1 }
                group.addTask { (n, await Self.original(of: segment.url)) }
            }
            for await (i, url) in group { found[i] = url }
            return found
        }
        var stillMuted: [Range<Double>] = []
        for (n, segment) in muted.enumerated() {
            if let original = originals[n] { lines[segment.line] = original.absoluteString } else { stillMuted.append(segment.time) }
        }
        // shortcut: con calidad automática gana la última lista cargada, que suele ser la que suena
        onMuted(Twitch.merged(stillMuted))
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// "12-muted.ts" → "12.ts" o "12-unmuted.ts", el que Twitch aún tenga.
    private static func original(of segment: URL) async -> URL? {
        let name = segment.lastPathComponent
        for replacement in [".", "-unmuted."] {
            let candidate = segment.deletingLastPathComponent()
                .appendingPathComponent(name.replacingOccurrences(of: "-muted.", with: replacement))
            var request = URLRequest(url: candidate, timeoutInterval: 5)
            request.httpMethod = "HEAD"
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return candidate
            }
        }
        return nil
    }

    private static func swapScheme(_ url: URL, to scheme: String) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        return components?.url ?? url
    }
}
