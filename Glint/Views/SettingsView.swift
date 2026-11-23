import SwiftUI

/// Preferencias del reproductor y del chat. Cada una se guarda con su clave en UserDefaults
/// y la lee la vista que la usa (con el mismo valor por defecto que aquí).
struct SettingsView: View {
    @AppStorage("levelGestures") private var levelGestures = true
    @AppStorage("chatTextSize") private var chatTextSize = ChatTextSize.normal
    @AppStorage("chatAnimation") private var chatAnimation = true
    @AppStorage("chatOverlay") private var chatOverlay = false
    @AppStorage("chatOverlayTrailing") private var overlayTrailing = false
    @AppStorage("chatOverlayOpacity") private var overlayOpacity = 1.0
    @AppStorage("autoClaimBonus") private var autoClaimBonus = true
    @Environment(Playback.self) private var playback

    var body: some View {
        List {
            Section {
                Toggle("Brillo y volumen con gestos", isOn: $levelGestures)
            } header: {
                Text("Reproductor")
            } footer: {
                Text("A pantalla completa, desliza arriba o abajo por el lado izquierdo para el brillo y por el derecho para el volumen.")
            }

            Section {
                Toggle("Reclamar el cofre de puntos solo", isOn: $autoClaimBonus)
                NavigationLink("Cofres reclamados") { ClaimHistoryView() }
                // Última comprobación (cada minuto mientras ves un directo): para saber si está funcionando
                Label(playback.pointsStatus ?? "Aún sin comprobar: pon un directo con tu cuenta y espera un minuto.",
                      systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Puntos del canal")
            } footer: {
                Text("Mientras ves un directo con tu cuenta, el cofre se reclama unos segundos después de aparecer, como si lo pulsaras tú.")
            }

            Section("Chat") {
                Picker("Tamaño del texto", selection: $chatTextSize) {
                    ForEach(ChatTextSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Animar los mensajes nuevos", isOn: $chatAnimation)
            }

            Section {
                Toggle("Chat sobre el vídeo", isOn: $chatOverlay)
                if chatOverlay {
                    Picker("Lado", selection: $overlayTrailing) {
                        Text("Izquierda").tag(false)
                        Text("Derecha").tag(true)
                    }
                    VStack(alignment: .leading) {
                        Text("Opacidad")
                        Slider(value: $overlayOpacity, in: 0.3...1) {
                            Text("Opacidad")
                        } minimumValueLabel: {
                            Image(systemName: "circle.dashed")
                        } maximumValueLabel: {
                            Image(systemName: "circle.fill")
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            } header: {
                Text("A pantalla completa")
            } footer: {
                Text("Los últimos mensajes flotan sobre la imagen, sin fondo. También se cambia desde ⚙︎ en el reproductor.")
            }
        }
        .animation(.snappy, value: chatOverlay)
        .navigationTitle("Ajustes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Historial de los cofres de puntos que se reclamaron solos.
struct ClaimHistoryView: View {
    @Environment(Library.self) private var library

    var body: some View {
        List(library.claims) { claim in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(claim.channel).font(.subheadline.weight(.medium))
                    Text(claim.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = claim.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer()
                if claim.error == nil {
                    Text(claim.gained.map { "+\(Format.count($0))" } ?? "✓")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.glint)
                }
            }
        }
        .overlay {
            if library.claims.isEmpty {
                ContentUnavailableView("Sin cofres todavía", systemImage: "gift",
                                       description: Text("Aparecerán aquí cuando se reclame alguno mientras ves un directo."))
            }
        }
        .toolbar {
            if !library.claims.isEmpty {
                Button("Borrar") { library.clearClaims() }
            }
        }
        .navigationTitle("Cofres reclamados")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Tamaño del texto del chat. "Normal" respeta el tamaño de letra del sistema.
enum ChatTextSize: Int, CaseIterable {
    case small, normal, large, extraLarge

    var label: String {
        switch self {
        case .small: "Pequeño"
        case .normal: "Normal"
        case .large: "Grande"
        case .extraLarge: "Muy grande"
        }
    }

    /// nil = el del sistema (Accesibilidad › Texto más grande sigue funcionando).
    var dynamicType: DynamicTypeSize? {
        switch self {
        case .small: .small
        case .normal: nil
        case .large: .xLarge
        case .extraLarge: .xxxLarge
        }
    }
}

extension View {
    /// Aplica el tamaño de texto del chat elegido en Ajustes.
    func chatTextSize(_ size: ChatTextSize) -> some View {
        transformEnvironment(\.dynamicTypeSize) { if let custom = size.dynamicType { $0 = custom } }
    }
}
