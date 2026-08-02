import SwiftData
import SwiftUI

/// Composição editorial: três eixos, o que mudou, e os registros de contexto.
/// Nenhum indicador único decide se o dia foi bom ou ruim.
struct TodayView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @EnvironmentObject private var health: AppleHealthSource

    @Query private var observations: [MetricObservation]
    @Query private var sleep: [SleepSession]
    @Query private var workouts: [WorkoutSession]
    @Query private var pressureSessions: [BloodPressureSession]
    @Query private var contextLogs: [DailyContextLog]

    @State private var showingContextSheet = false

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }
            .background(Palette.background(scheme))
            .navigationTitle("Hoje")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingContextSheet) {
                ContextEntrySheet(day: today)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            SectionHeading(title: "Eixos do dia",
                           subtitle: "Cada eixo compara o dado de hoje com a sua "
                                   + "própria mediana recente.")

            axesLayout

            whatChanged

            contextPanel

            NavigationLink { SafetyView() } label: {
                Panel {
                    Text("Quando procurar ajuda")
                        .font(.headline)
                        .foregroundStyle(Palette.ink(scheme))
                    Text(SafetyNotice.headline)
                        .font(.subheadline)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Greeting.current)
                .font(.system(.largeTitle, design: .default).weight(.semibold))
                .foregroundStyle(Palette.ink(scheme))
            Text(Format.fullDate.string(from: Date()).capitalized)
                .font(.title3)
                .foregroundStyle(Palette.inkMuted(scheme))

            HStack(spacing: 8) {
                MetaTag(text: syncLabel)
                MetaTag(text: "Dados de hoje: \(dayAvailability.label)")
            }
            .padding(.top, 2)

            Button {
                showingContextSheet = true
            } label: {
                Text("Registrar contexto")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .background(Palette.surfaceRaised(scheme),
                        in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(Palette.ink(scheme))
            .padding(.top, 6)
        }
    }

    private var syncLabel: String {
        switch health.status {
        case .authorized:
            if let finished = health.lastSummary?.finishedAt {
                return "Sincronizado \(Format.dayAndTime.string(from: finished))"
            }
            return "Fontes conectadas"
        case .notRequested: return "Fontes não conectadas"
        case .unavailable: return "Saúde indisponível"
        case .entitlementMissing: return "Saúde sem permissão neste build"
        case .failed: return "Falha na última sincronização"
        }
    }

    // MARK: - Eixos

    private var axesLayout: some View {
        Group {
            if sizeClass == .regular {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16),
                                    GridItem(.flexible(), spacing: 16)],
                          spacing: 16) {
                    recoveryAxis
                    loadAxis
                    pressureAxis
                }
            } else {
                VStack(spacing: 16) {
                    recoveryAxis
                    loadAxis
                    pressureAxis
                }
            }
        }
    }

    private var sleepTrend: TrendAnalysis {
        Baseline.analyse(series: Query.sleepMinutes(sleep),
                         metricLabel: "Sono", unit: "min", period: .d14,
                         decimals: 0, directMeasurement: false,
                         higherLabel: "acima", lowerLabel: "abaixo")
    }

    private var sleepingHRTrend: TrendAnalysis {
        Baseline.analyse(series: Query.dailyValues(observations, kind: .sleepingHeartRate),
                         metricLabel: "FC durante o sono", unit: "bpm", period: .d14,
                         decimals: 0, directMeasurement: false)
    }

    private var hrvTrend: TrendAnalysis {
        Baseline.analyse(series: Query.dailyValues(observations, kind: .heartRateVariability),
                         metricLabel: "Variabilidade da FC", unit: "ms", period: .d14,
                         decimals: 0, directMeasurement: false)
    }

    private var recoveryAxis: some View {
        NavigationLink { RecoveryView() } label: {
            Panel {
                axisHeader("Recuperação e sono",
                           availability: recoveryAvailability)
                Text(sleepSentence)
                    .font(.body)
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if !hrvTrend.confidence.supportsInterpretation {
                    Text("Interpretação limitada: não há variabilidade da "
                       + "frequência cardíaca suficiente no período.")
                        .font(.caption)
                        .foregroundStyle(Palette.inkMuted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var sleepSentence: String {
        guard sleepTrend.confidence.supportsInterpretation,
              let current = sleepTrend.currentValue,
              let base = sleepTrend.baseline else {
            return TrendAnalysis.insufficientData
        }
        let delta = current - base
        if abs(delta) < 20 {
            return "Seu sono ficou próximo da sua mediana de 14 dias "
                 + "(\(Format.duration(minutes: current)))."
        }
        return "Seu sono foi \(Format.duration(minutes: abs(delta))) "
             + (delta < 0 ? "mais curto" : "mais longo")
             + " que sua mediana de 14 dias (\(Format.duration(minutes: current)))."
    }

    private var loadAxis: some View {
        NavigationLink { TrainingView() } label: {
            Panel {
                axisHeader("Carga e movimento", availability: loadAvailability)
                Text(loadSentence)
                    .font(.body)
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
    }

    private var weeklyLoad: [(weekStart: Date, load: Double, sessions: Int)] {
        Query.weeklyLoad(workouts, maxHeartRate: nil)
    }

    private var loadSentence: String {
        let weeks = weeklyLoad
        guard let current = weeks.first else {
            return "Ainda não há sessões registradas nesta semana."
        }
        let prior = Array(weeks.dropFirst().prefix(4))
        guard prior.count >= 2, let average = Baseline.mean(prior.map(\.load)),
              average > 0 else {
            return "\(current.sessions) "
                 + (current.sessions == 1 ? "sessão registrada" : "sessões registradas")
                 + " nesta semana. Ainda não há semanas suficientes para comparação."
        }
        let delta = (current.load - average) / average * 100
        if abs(delta) < 15 {
            return "A carga desta semana está próxima da média das últimas "
                 + "\(prior.count) semanas."
        }
        return "A carga desta semana está \(Format.signed(delta, 0, unit: "%")) "
             + "versus a média das últimas \(prior.count) semanas."
    }

    private var pressureAxis: some View {
        NavigationLink { BloodPressureView() } label: {
            Panel {
                axisHeader("Pressão e saúde cardiovascular",
                           availability: pressureAvailability)
                Text(pressureSentence)
                    .font(.body)
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
    }

    private var morningSessionsThisWeek: Int {
        let calendar = Calendar(identifier: .iso8601)
        guard let week = calendar.dateInterval(of: .weekOfYear, for: Date()) else {
            return 0
        }
        return Query.morningSessions(pressureSessions)
            .filter { week.contains($0.date) }.count
    }

    private var pressureSentence: String {
        let count = morningSessionsThisWeek
        if count == 0 {
            return "Ainda não há medida matinal padronizada nesta semana."
        }
        let plural = count == 1 ? "medida matinal válida" : "medidas matinais válidas"
        return "Há \(count) \(plural) de pressão nesta semana."
    }

    @ViewBuilder
    private func axisHeader(_ title: String, availability: DataAvailability) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Palette.ink(scheme))
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.inkMuted(scheme))
        }
        MetaTag(text: "Disponibilidade de dados: \(availability.label)")
    }

    private var recoveryAvailability: DataAvailability {
        var present = 0
        if sleepTrend.currentValue != nil { present += 1 }
        if sleepingHRTrend.currentValue != nil { present += 1 }
        if hrvTrend.currentValue != nil { present += 1 }
        return .from(present: present, total: 3)
    }

    private var loadAvailability: DataAvailability {
        .from(present: weeklyLoad.isEmpty ? 0 : 1, total: 1)
    }

    private var pressureAvailability: DataAvailability {
        let last14 = Query.morningSessions(pressureSessions).filter {
            $0.date > Date().addingTimeInterval(-14 * 86_400)
        }.count
        return .from(present: last14, total: 4)
    }

    private var dayAvailability: DataAvailability {
        let values = [recoveryAvailability, loadAvailability, pressureAvailability]
        let complete = values.filter { $0 == .complete }.count
        return .from(present: complete, total: values.count)
    }

    // MARK: - O que mudou

    private var whatChanged: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "O que mudou",
                           subtitle: "Comparações com a sua própria mediana. "
                                   + "Descrevem o registro, não a causa.")
            let items = changes
            if items.isEmpty {
                Panel {
                    Text(TrendAnalysis.insufficientData)
                        .font(.body)
                        .foregroundStyle(Palette.inkMuted(scheme))
                }
            } else {
                ForEach(items, id: \.self) { line in
                    Panel(padding: 15) {
                        Text(line)
                            .font(.body)
                            .foregroundStyle(Palette.inkSecondary(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Até três mudanças, sempre com dado, janela e comparação.
    private var changes: [String] {
        var out: [String] = []

        if sleepTrend.confidence.supportsInterpretation,
           let current = sleepTrend.currentValue, let base = sleepTrend.baseline,
           abs(current - base) >= 30 {
            out.append("Duração do sono: \(Format.duration(minutes: current)), "
                     + "\(Format.duration(minutes: abs(current - base))) "
                     + (current < base ? "abaixo" : "acima")
                     + " da sua mediana de 14 dias.")
        }

        if sleepingHRTrend.confidence.supportsInterpretation,
           let current = sleepingHRTrend.currentValue,
           let base = sleepingHRTrend.baseline, abs(current - base) >= 3 {
            out.append("FC durante o sono: "
                     + "\(Format.signed(current - base, 0, unit: "bpm")) versus sua "
                     + "mediana de 14 dias.")
        }

        let last14 = Query.morningSessions(pressureSessions).filter {
            $0.date > Date().addingTimeInterval(-14 * 86_400)
        }.count
        if last14 > 0 {
            out.append("Pressão matinal: \(last14) "
                     + (last14 == 1 ? "sessão completa" : "sessões completas")
                     + " nos últimos 14 dias.")
        }

        let weeks = weeklyLoad
        if let current = weeks.first {
            let prior = Array(weeks.dropFirst().prefix(4))
            if prior.count >= 2, let average = Baseline.mean(prior.map(\.load)),
               average > 0 {
                let delta = (current.load - average) / average * 100
                if abs(delta) >= 15 {
                    out.append("Carga de treino: "
                             + "\(Format.signed(delta, 0, unit: "%")) versus a média "
                             + "das \(prior.count) semanas anteriores.")
                }
            }
        }

        return Array(out.prefix(3))
    }

    // MARK: - Contexto

    private var contextPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Registros que ajudam a explicar",
                           subtitle: "Contexto informado por você. Não é prova de "
                                   + "causa.")
            let tags = Query.contextTags(contextLogs, on: today)
            Panel {
                if tags.isEmpty {
                    Text("Nenhum registro de contexto hoje.")
                        .font(.body)
                        .foregroundStyle(Palette.inkMuted(scheme))
                } else {
                    FlowTags(tags: tags.map(\.label))
                }
            }
        }
    }
}

/// Etiquetas que quebram linha, sem depender de API de layout mais recente.
struct FlowTags: View {
    @Environment(\.colorScheme) private var scheme
    let tags: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { MetaTag(text: $0) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var rows: [[String]] {
        var out: [[String]] = []
        var current: [String] = []
        var width = 0
        for tag in tags {
            let estimate = tag.count + 4
            if width + estimate > 34, !current.isEmpty {
                out.append(current)
                current = []
                width = 0
            }
            current.append(tag)
            width += estimate
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
