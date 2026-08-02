import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Qualidade dos dados, respiração coerente e ajustes.
///
/// Esta tela existe porque a incerteza vem antes das conclusões. Antes de olhar
/// qualquer score, dá para ver de onde cada número veio, quantos dias existem,
/// há quanto tempo foi a última medida e se já há baseline pessoal.
struct DataQualityView: View {
    let entries: [DailyEntry]
    @ObservedObject var health: HealthKitBridge
    @ObservedObject var band: BandManager
    @Binding var sleepGoal: Double

    @Environment(\.modelContext) private var context
    @State private var apiKeyDraft = ""
    @State private var hasKey = KeychainStore.hasKey
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var syncMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("A incerteza vem antes das conclusões: fonte, cobertura "
                       + "nos últimos 30 dias, lacuna desde a última medida e se "
                       + "há baseline pessoal. Sinal ruidoso não deve parecer "
                       + "preciso.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)

                    provenanceCard
                    healthCard
                    BreathingCard()
                    unvalidatedCard

                    SectionLabel(text: "Ajustes").padding(.top, 8)
                    settingsCard
                    backupCard

                    if !band.packets.isEmpty { packetCard }

                    Text("Todos os dados vivem neste aparelho. Sem servidor, sem "
                       + "conta, sem telemetria. Uso pessoal, não comercial.")
                        .font(.caption2).foregroundStyle(Theme.muted).padding(.top, 6)
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Dados")
            .navigationBarTitleDisplayMode(.inline)
            .fileExporter(isPresented: $showingExporter, document: backupDocument(),
                          contentType: .json,
                          defaultFilename: "vwarloop-backup") { _ in }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.json]) { result in
                if case .success(let url) = result { importBackup(from: url) }
            }
        }
    }

    private var provenanceCard: some View {
        Card {
            ForEach(Provenance.evaluate(entries)) { metric in
                VStack(alignment: .leading, spacing: 6) {
                    Text(metric.label).font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    HStack(spacing: 6) {
                        pill("\(metric.coverage30d)/30 dias")
                        pill("lacuna " + (metric.gapDays.map { "\($0)d" } ?? "—"))
                        pill(metric.quality.label, Theme.color(for: metric.quality))
                    }
                    Text("fonte: \(metric.source.label) · "
                       + (metric.hasBaseline
                          ? "baseline pessoal estabelecido"
                          : "sem baseline ainda (\(metric.baselineN)/14)"))
                        .font(.caption2).foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 5)
                if metric.id != "temperature" { Divider().overlay(Theme.line) }
            }
        }
    }

    private func pill(_ text: String, _ color: Color = Theme.inkSecondary) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
    }

    private var healthCard: some View {
        Card {
            Text("Saúde da Apple").font(.headline).foregroundStyle(Theme.ink)
            Text("VWAR Loop Life → G Band → Saúde da Apple → este app. Ative a "
               + "integração com a Saúde dentro do G Band e autorize a leitura "
               + "aqui.")
                .font(.caption).foregroundStyle(Theme.muted)

            switch health.status {
            case .unavailable:
                Text("Saúde indisponível neste aparelho.")
                    .font(.caption).foregroundStyle(Theme.critical)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(Theme.critical)
            case .notRequested:
                Button("Autorizar leitura da Saúde") {
                    Task { await health.requestAuthorization() }
                }
            case .authorized:
                Button(health.isSyncing ? "Sincronizando..." : "Sincronizar agora") {
                    Task { await sync() }
                }
                .disabled(health.isSyncing)
            }

            if let syncMessage {
                Text(syncMessage).font(.caption).foregroundStyle(Theme.inkSecondary)
            }

            Text("A glicose escrita pelo G Band não é importada. O iOS não informa "
               + "se você negou a leitura de um tipo, então um resultado vazio "
               + "pode significar falta de permissão ou falta de dado — não "
               + "assumimos qual.")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
    }

    private var unvalidatedCard: some View {
        Card {
            Text("Métricas ignoradas de propósito")
                .font(.headline).foregroundStyle(Theme.ink)
            Text(UnvalidatedMetrics.names.joined(separator: " · "))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.serious)
            Text(UnvalidatedMetrics.explanation)
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private var settingsCard: some View {
        Card {
            Text("Meta de sono").font(.subheadline).foregroundStyle(Theme.inkSecondary)
            HStack {
                Slider(value: $sleepGoal, in: 5...10, step: 0.5)
                Text(String(format: "%.1f h", sleepGoal))
                    .monospacedDigit().foregroundStyle(Theme.ink).frame(width: 56)
            }

            Divider().overlay(Theme.line).padding(.vertical, 4)

            Text("Chave da API do coach").font(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
            Text(hasKey
                 ? "Chave salva no Keychain deste aparelho."
                 : "Sem chave. O coach fica indisponível; o resto do app funciona.")
                .font(.caption).foregroundStyle(Theme.muted)
            SecureField("sk-ant-...", text: $apiKeyDraft)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            HStack {
                Button("Salvar chave") {
                    KeychainStore.save(apiKeyDraft)
                    apiKeyDraft = ""
                    hasKey = KeychainStore.hasKey
                }
                .disabled(apiKeyDraft.isEmpty)
                if hasKey {
                    Spacer()
                    Button("Remover", role: .destructive) {
                        KeychainStore.delete()
                        hasKey = false
                    }
                }
            }
            .font(.subheadline)
        }
    }

    private var backupCard: some View {
        Card {
            Text("Backup").font(.headline).foregroundStyle(Theme.ink)
            Text("O JSON é o mesmo formato do web app, então dá para migrar nos "
               + "dois sentidos.")
                .font(.caption).foregroundStyle(Theme.muted)
            HStack {
                Button("Exportar") { showingExporter = true }
                Spacer()
                Button("Importar") { showingImporter = true }
            }
            .font(.subheadline)
            Text("\(entries.count) dias registrados · sequência de "
               + "\(ScoreEngine.streak(entries)) dias")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
    }

    /// Aparece só quando há captura bruta — a pulseira falando protocolo
    /// proprietário em vez do serviço padrão de frequência cardíaca.
    private var packetCard: some View {
        Card {
            Text("Captura BLE bruta").font(.headline).foregroundStyle(Theme.ink)
            Text("\(band.packets.count) pacotes gravados. Mesmo formato que "
               + "`tools/vwar_ble.py analyze` lê, para decodificar o protocolo "
               + "da JieLi.")
                .font(.caption).foregroundStyle(Theme.muted)
            ForEach(band.packets.suffix(6)) { packet in
                Text(packet.hex)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            ShareLink(item: band.exportPacketLog()) {
                Text("Exportar log de pacotes").font(.subheadline)
            }
        }
    }

    // MARK: - Ações

    private func sync() async {
        let samples = await health.fetchRecentDays()
        guard !samples.isEmpty else {
            syncMessage = "Nenhum dado retornado. Verifique se o G Band está "
                        + "escrevendo na Saúde e se a leitura foi autorizada."
            return
        }
        var touched = 0
        for sample in samples {
            let entry = EntryStore.entry(for: sample.day, in: context, existing: entries)
            // Só preenche o que está vazio: o que você digitou tem prioridade.
            entry.fillIfEmpty(\.restingHR, with: sample.restingHR)
            entry.fillIfEmpty(\.hrv, with: sample.hrv)
            entry.fillIfEmpty(\.spo2, with: sample.spo2)
            entry.fillIfEmpty(\.sleepHours, with: sample.sleepHours)
            entry.fillIfEmpty(\.steps, with: sample.steps)
            entry.fillIfEmpty(\.activeEnergy, with: sample.activeEnergy)
            entry.fillIfEmpty(\.bodyTemperature, with: sample.bodyTemperature)
            entry.fillIfEmpty(\.weight, with: sample.weight)
            if entry.source == .manual && entry.updatedAt.timeIntervalSinceNow > -2 {
                entry.source = .healthKit
            }
            touched += 1
        }
        try? context.save()
        syncMessage = "\(touched) dias atualizados a partir da Saúde."
    }

    private func backupDocument() -> BackupDocument {
        let payload = BackupFile(
            exported_at: ISO8601DateFormatter().string(from: Date()),
            entries: entries.map(EntryDTO.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return BackupDocument(data: (try? encoder.encode(payload)) ?? Data())
    }

    private func importBackup(from url: URL) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let backup = try? JSONDecoder().decode(BackupFile.self, from: data)
        else {
            syncMessage = "Arquivo inválido."
            return
        }
        var imported = 0
        for dto in backup.entries {
            guard let day = dto.parsedDay else { continue }
            let entry = EntryStore.entry(for: day, in: context, existing: entries)
            dto.apply(to: entry)
            imported += 1
        }
        try? context.save()
        syncMessage = "\(imported) dias importados."
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Respiração coerente: 4 segundos inspirando, 6 expirando, sem pausa.
///
/// A ~5,5 respirações por minuto os ritmos do coração e da respiração entram em
/// fase. É a intervenção respiratória mais pesquisada em psicofisiologia para
/// elevar HRV e restaurar tônus parassimpático.
struct BreathingCard: View {
    @State private var running = false
    @State private var inhaling = true
    @State private var remaining = 300
    @State private var timer: Timer?

    private let inhale = 4.0
    private let exhale = 6.0

    var body: some View {
        Card {
            Text("Respiração coerente").font(.headline).foregroundStyle(Theme.ink)

            VStack(spacing: 16) {
                Circle()
                    .fill(RadialGradient(colors: [Theme.accent, Theme.accent.opacity(0.35)],
                                         center: .init(x: 0.5, y: 0.4),
                                         startRadius: 4, endRadius: 110))
                    .frame(width: 160, height: 160)
                    .scaleEffect(running ? (inhaling ? 1.0 : 0.55) : 0.7)
                    .animation(.easeInOut(duration: inhaling ? inhale : exhale),
                               value: inhaling)
                    .animation(.easeInOut(duration: 0.4), value: running)

                Text(running ? (inhaling ? "Inspire" : "Expire") : "Pronto")
                    .font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)

                Text(running
                     ? "Faltam \(remaining / 60):\(String(format: "%02d", remaining % 60))"
                     : "Inspire 4s · Expire 6s · ~5,5 rpm · 5 min")
                    .font(.caption).foregroundStyle(Theme.muted).monospacedDigit()

                Button(running ? "Parar" : "Iniciar 5 min") {
                    running ? stop() : start()
                }
                .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            Text("A ~5,5 respirações por minuto os ritmos do coração e da "
               + "respiração se sincronizam. É a intervenção respiratória mais "
               + "pesquisada para elevar HRV e restaurar o tônus parassimpático.")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        running = true
        inhaling = true
        remaining = 300
        var elapsed = 0.0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            elapsed += 0.5
            remaining = max(0, 300 - Int(elapsed))
            // Ciclo de 10s: inspira nos primeiros 4, expira nos 6 seguintes.
            let phase = elapsed.truncatingRemainder(dividingBy: inhale + exhale)
            let shouldInhale = phase < inhale
            if shouldInhale != inhaling { inhaling = shouldInhale }
            if remaining == 0 { stop() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        running = false
    }
}
