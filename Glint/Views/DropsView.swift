import SwiftUI

/// Tus drops en curso, como el inventario de la app de Twitch: cada campaña con sus drops, lo que
/// llevas visto y el botón para reclamarlos cuando están listos. El progreso sube viendo directos
/// del juego con drops activos (la app le dice a Twitch que estás viendo, igual que para los cofres).
struct DropsView: View {
    @Environment(Account.self) private var account
    @State private var campaigns: [Twitch.DropCampaign]?
    @State private var failure: String?
    @State private var claiming: String?

    var body: some View {
        List {
            if let failure {
                Section { Text(failure).foregroundStyle(.secondary) }
            }
            if let campaigns {
                ForEach(campaigns) { campaign in
                    Section {
                        ForEach(campaign.timeBasedDrops ?? []) { drop in row(drop) }
                    } header: {
                        header(campaign)
                    }
                }
            } else if failure == nil {
                // La primera vez puede leerse de la web de Twitch: tarda unos segundos
                ProgressView("Cargando drops…").frame(maxWidth: .infinity)
            }
        }
        .overlay {
            if campaigns?.isEmpty == true {
                ContentUnavailableView("Sin drops en curso", systemImage: "gift",
                                       description: Text("Ve un directo con drops activos (sale en el canal) y aparecerán aquí."))
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .navigationTitle("Drops")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ campaign: Twitch.DropCampaign) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: campaign.game?.boxArtURL.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: {
                Color.white.opacity(0.08)
            }
            .frame(width: 30, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(campaign.name ?? "Campaña").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text([campaign.game?.displayName, campaign.endAt.map { "hasta el \($0.formatted(date: .abbreviated, time: .shortened))" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
            }
        }
        .textCase(nil)
    }

    private func row(_ drop: Twitch.DropCampaign.Drop) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: drop.image) { $0.resizable().scaledToFit() } placeholder: { Image(systemName: "gift") }
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(drop.title).font(.subheadline)
                ProgressView(value: drop.progress).tint(Color.glint)
                Text(drop.claimed ? "Reclamado" : "\(drop.watched) de \(drop.required) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if drop.claimable, let id = drop.`self`?.dropInstanceID {
                Button("Reclamar") { Task { await claim(id) } }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.glint)
                    .foregroundStyle(.black)
                    .disabled(claiming != nil)
            } else if drop.claimed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.glint)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        guard let token = account.token else { return }
        // En una tarea propia: SwiftUI cancela la de "tirar para recargar" y la vía web tarda segundos
        switch await Task(operation: { try await Twitch.dropsInProgress(token: token) }).result {
        case .success(let loaded):
            campaigns = loaded
            failure = nil
        case .failure(let error):
            failure = "No se pudieron cargar tus drops: \(error.localizedDescription)"
        }
    }

    private func claim(_ instanceID: String) async {
        guard let token = account.token else { return }
        claiming = instanceID
        defer { claiming = nil }
        var problem: String?
        do {
            try await Twitch.claimDrop(instanceID: instanceID, token: token)
        } catch {
            problem = "No se pudo reclamar: \(error.localizedDescription)"
        }
        await load()
        if let problem { failure = problem }
    }
}
