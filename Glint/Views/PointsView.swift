import SwiftUI

/// Puntos del canal hechos en la app: tu saldo, el cofre de bonificación y las recompensas
/// de ese canal (cada uno tiene las suyas, con su color e imagen). Predicciones y encuestas
/// siguen en la web de Twitch.
struct PointsView: View {
    let login: String
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var points: Twitch.Points?
    @State private var failure: String?
    @State private var chosen: Twitch.Reward?
    @State private var text = ""
    @State private var working: String?
    @State private var notice: String?
    @State private var showWeb = false
    @State private var bits: Int?
    @State private var showBits = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let points {
                        header(points)
                        if points.rewards.isEmpty {
                            Text("Este canal no tiene recompensas propias.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                                ForEach(points.rewards) { reward in
                                    RewardCard(reward: reward, affordable: (points.balance ?? 0) >= reward.cost,
                                               working: working == reward.id) { choose(reward) }
                                }
                            }
                        }
                    } else if let failure {
                        ErrorState(message: failure) { await load() }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    }

                    // Bits: se usan escribiendo "Cheer100" en el chat; se compran en la web de Twitch
                    Button { showBits = true } label: {
                        Label(bits.map { "Tus bits: \($0.formatted()) · Conseguir más" } ?? "Conseguir bits", systemImage: "diamond.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color(red: 0.72, green: 0.52, blue: 1))

                    Button { showWeb = true } label: {
                        Label("Predicciones y encuestas", systemImage: "chart.bar.xaxis")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(.glint)
                }
                .padding(16)
            }
            .refreshable { await load() }
            .navigationTitle(points?.name ?? "Puntos del canal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } }
            }
            .overlay(alignment: .bottom) {
                if let notice {
                    Text(notice)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: notice)
            .alert(chosen?.title ?? "", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } })) {
                if chosen?.isUserInputRequired == true {
                    TextField("Tu mensaje", text: $text)
                }
                Button("Cancelar", role: .cancel) {}
                Button("Canjear por \(Format.count(chosen?.cost ?? 0))") {
                    if let chosen { Task { await redeem(chosen) } }
                }
                .disabled(chosen?.isUserInputRequired == true && text.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                if let prompt = chosen?.prompt, !prompt.isEmpty { Text(prompt) }
            }
            .sheet(isPresented: $showWeb, onDismiss: { Task { await load() } }) {
                if let url = URL(string: "https://www.twitch.tv/popout/\(login)/chat?popout=") {
                    TwitchWebSheet(title: "Twitch", url: url,
                                   hint: "Predicciones, encuestas y lo que Twitch no deje hacer desde la app.")
                }
            }
        }
        .task { await load() }
        .task { if let token = account.token { bits = await Twitch.bitsBalance(token: token) } }
        .sheet(isPresented: $showBits) {
            if let url = URL(string: "https://www.twitch.tv/bits-checkout/select") {
                TwitchWebSheet(title: "Bits", url: url, hint: "Para usarlos, escribe en el chat Cheer seguido de la cantidad (Cheer100).")
            }
        }
    }

    private func header(_ points: Twitch.Points) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: points.iconURL) { $0.resizable().scaledToFit() } placeholder: {
                Image(systemName: "star.circle.fill").resizable().foregroundStyle(Color.glint)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(points.balance.map { $0.formatted() } ?? "–")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(points.name ?? "Puntos del canal").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let claimID = points.claimID {
                Button {
                    Task { await claim(claimID, channelID: points.channelID) }
                } label: {
                    Label("Reclamar bonus", systemImage: "gift.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(.black)
                        .background(Color.glint, in: Capsule())
                }
                .buttonStyle(PressStyle())
                .disabled(working == "claim")
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Acciones

    private func load() async {
        guard let token = account.token else { return }
        do {
            let loaded = try await Twitch.points(login, token: token)
            withAnimation(.snappy) { points = loaded }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func choose(_ reward: Twitch.Reward) {
        text = ""
        chosen = reward
    }

    private func redeem(_ reward: Twitch.Reward) async {
        guard let token = account.token, let channelID = points?.channelID else { return }
        working = reward.id
        defer { working = nil }
        do {
            let input = reward.isUserInputRequired == true ? text : nil
            try await Twitch.redeem(reward, channelID: channelID, text: input, token: token)
            show("Canjeado: \(reward.title)")
            await load()
        } catch {
            fail(error)
        }
    }

    private func claim(_ claimID: String, channelID: String) async {
        guard let token = account.token else { return }
        working = "claim"
        defer { working = nil }
        do {
            try await Twitch.claimBonus(channelID: channelID, claimID: claimID, token: token)
            show("Bonus reclamado")
            await load()
        } catch {
            fail(error)
        }
    }

    /// Si Twitch no lo deja hacer desde la app, se ofrece su web para hacerlo allí.
    private func fail(_ error: Error) {
        show(error.localizedDescription)
        if error.localizedDescription == "Twitch no lo permitió desde la app" { showWeb = true }
    }

    private func show(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if notice == message { notice = nil }
        }
    }
}

private struct RewardCard: View {
    let reward: Twitch.Reward
    let affordable: Bool
    let working: Bool
    let action: () -> Void

    var body: some View {
        let enabled = reward.available && affordable && !working
        Button(action: action) {
            VStack(spacing: 8) {
                AsyncImage(url: reward.imageURL) { $0.resizable().scaledToFit() } placeholder: {
                    Image(systemName: "gift").font(.title2)
                }
                .frame(width: 44, height: 44)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay { if working { ProgressView().tint(.white) } }

                Text(reward.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
                Label(Format.count(reward.cost), systemImage: "star.circle.fill")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(affordable ? Color.glint : .secondary)
            }
            .padding(10)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .accessibilityLabel("\(reward.title), \(Format.count(reward.cost)) puntos")
        .accessibilityHint(reward.available ? (affordable ? "" : "No tienes puntos suficientes") : "No disponible ahora")
    }

    /// Color que el canal eligió para la recompensa.
    private var color: Color {
        guard let hex = reward.backgroundColor, hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else {
            return Color.glint.opacity(0.4)
        }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}
