import SwiftData
import SwiftUI

/// Três camadas expostas: sinal fisiológico, sono e carga recente.
/// Nenhuma nota absoluta; a leitura descreve posição relativa à faixa da pessoa.
struct RecoveryView: View {
    @Environment(\.colorScheme) private var scheme
    @Query private var observations: [MetricObservation]
    @Query private var sleep: [SleepSession]
    @Query private var workouts: [WorkoutSession]
    @Query private var contextLogs: [DailyContextLog]

    private func trend(_ kind: MetricKind, decimals: Int = 0) -> TrendAnalysis {
        Baseline.analyse(series: Query.dailyValues(observations, kind: kind),
                         metricLabel: kind.label, unit: kind.unit, period: .d14,
                         decimals: decimals, directMeasurement: false)
    }

    private var sleepTrend: TrendAnalysis {
        Baseline.analyse(series: Query.sleepMinutes(sleep),
                         metricLabel: "Duração do sono", unit: "min",
                         period: .d14, decimals: 0, directMeasurement: false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SectionHeading(
                        title: "Recuperação",
                        subtitle: "Leitura das tendências recentes de sono, "
                                + "frequência cardíaca, variabilidade e carga.")

                    availabilityPanel
                    interpretationPanel

                    SectionHeading(title: "Sinal fisiológico")
                    Panel {
                        TrendRow(trend: trend(.restingHeartRate))
                        Divider().overlay(Palette.hairline(scheme))
                        TrendRow(trend: trend(.sleepingHeartRate))
                        Divider().overlay(Palette.hairline(scheme))
                        TrendRow(trend: trend(.heartRateVariability))
                        Divider().overlay(Palette.hairline(scheme))
                        TrendRow(trend: trend(.respiratoryRate, decimals: 1))
                        Divider().overlay(Palette.hairline(scheme))
                        TrendRow(trend: trend(.wristTemperature, decimals: 1))
                        Text("Temperatura cutânea aparece apenas como tendência "
                           + "individual. Não indica febre nem condição clínica.")
                            .font(.caption)
                            .foregroundStyle(Palette.inkMuted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    SectionHeading(title: "Sono")
                    Panel { TrendRow(trend: sleepTrend) }

                    SectionHeading(title: "Carga recente")
                    Panel { loadSummary }

                    ForEach(insights) { InsightPanel(insight: $0) }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.background(scheme))
            .navigationTitle("Recuperação")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var contributors: [TrendAnalysis] {
        [sleepTrend, trend(.sleepingHeartRate), trend(.heartRateVariability),
         trend(.restingHeartRate)]
    }

    private var availability: DataAvailability {
        let present = contributors.filter { $0.currentValue != nil }.count
        return .from(present: present, total: contributors.count)
    }

    private var availabilityPanel: some View {
        Panel {
            Text("Disponibilidade de dados")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.inkSecondary(scheme))
            Text(availability.label)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.ink(scheme))
            let missing = contributors.filter { $0.currentValue == nil }
                .map(\.metricLabel)
            if !missing.isEmpty {
                Text("Sem leitura no período: "
                   + missing.joined(separator: ", ") + ".")
                    .font(.caption)
                    .foregroundStyle(Palette.inkMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Frase de posição relativa, com contribuintes e ausências declarados.
    private var interpretationPanel: some View {
        let usable = contributors.filter { $0.confidence.supportsInterpretation }
        let deviations = usable.compactMap { t -> Double? in
            guard let current = t.currentValue, let base = t.baseline,
                  base != 0 else { return nil }
            // FC de repouso e FC noturna acima do baseline pesam na direção
            // oposta às demais.
            let raw = (current - base) / abs(base)
            let inverted = t.metricLabel.contains("FC")
            return inverted ? -raw : raw
        }

        return Panel {
            Text("Tendência de recuperação")
                .font(.headline)
                .foregroundStyle(Palette.ink(scheme))

            if usable.count < 2 || deviations.isEmpty {
                Text(TrendAnalysis.insufficientData)
                    .font(.body)
                    .foregroundStyle(Palette.inkMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let average = Baseline.mean(deviations) ?? 0
                let phrase: String
                if average < -0.05 {
                    phrase = "Recuperação abaixo da sua faixa recente"
                } else if average > 0.05 {
                    phrase = "Recuperação acima da sua faixa recente"
                } else {
                    phrase = "Recuperação próxima da sua faixa recente"
                }
                Text(phrase)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.ink(scheme))

                Text("Contribuíram: "
                   + usable.map(\.metricLabel).joined(separator: ", ")
                   + ". Comparação com a mediana de 14 dias.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                let missing = contributors
                    .filter { !$0.confidence.supportsInterpretation }
                    .map(\.metricLabel)
                if !missing.isEmpty {
                    Text("Sem dados suficientes: " + missing.joined(separator: ", ")
                       + ". A confiança da leitura é parcial.")
                        .font(.caption)
                        .foregroundStyle(Palette.inkMuted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Este indicador descreve tendências dos seus registros. Não "
               + "substitui sintomas, percepção de esforço nem avaliação médica.")
                .font(.caption)
                .foregroundStyle(Palette.inkMuted(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loadSummary: some View {
        let weeks = Query.weeklyLoad(workouts, maxHeartRate: nil)
        let last7 = workouts.filter {
            $0.start > Date().addingTimeInterval(-7 * 86_400)
        }
        let trainingDays = Set(last7.map(\.day)).count

        return VStack(alignment: .leading, spacing: 8) {
            Text("Você treinou em \(trainingDays) dos últimos 7 dias.")
                .font(.body)
                .foregroundStyle(Palette.inkSecondary(scheme))
            if let current = weeks.first {
                Text("\(current.sessions) "
                   + (current.sessions == 1 ? "sessão" : "sessões")
                   + " nesta semana.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkMuted(scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var insights: [Insight] {
        let today = Calendar.current.startOfDay(for: Date())
        let tags = Query.contextTags(contextLogs, on: today)
        var out: [Insight] = []
        let hrvAvailable = trend(.heartRateVariability).currentValue != nil
        if let a = InsightBuilder.sleepDuration(trend: sleepTrend, contextTags: tags,
                                                hrvAvailable: hrvAvailable) {
            out.append(a)
        }
        if let b = InsightBuilder.sleepingHeartRate(trend: trend(.sleepingHeartRate),
                                                    contextTags: tags) {
            out.append(b)
        }
        return out
    }
}

// MARK: - Treino

struct TrainingView: View {
    @Environment(\.colorScheme) private var scheme
    @Query(sort: \WorkoutSession.start, order: .reverse)
    private var workouts: [WorkoutSession]
    @Query private var observations: [MetricObservation]

    private var weeks: [(weekStart: Date, load: Double, sessions: Int)] {
        Query.weeklyLoad(workouts, maxHeartRate: nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SectionHeading(
                        title: "Treino",
                        subtitle: "Carga, consistência e distribuição de "
                                + "intensidade a partir das sessões registradas.")

                    loadPanel
                    intensityPanel
                    aerobicPanel
                    strengthPanel
                    sessionsPanel

                    if let insight = InsightBuilder.trainingLoad(
                        currentWeek: weeks.first?.load ?? 0,
                        priorAverage: Baseline.mean(
                            weeks.dropFirst().prefix(4).map(\.load)) ?? 0,
                        sessionCount: weeks.first?.sessions ?? 0,
                        sampleWeeks: min(4, max(0, weeks.count - 1))) {
                        InsightPanel(insight: insight)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.background(scheme))
            .navigationTitle("Treino")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var loadPanel: some View {
        Panel {
            Text("Carga por semana")
                .font(.headline)
                .foregroundStyle(Palette.ink(scheme))
            SeriesChart(series: [
                .init(id: "load", name: "Carga", unit: "u.a.", decimals: 0,
                      points: weeks.map { (day: $0.weekStart, value: $0.load) },
                      color: { Palette.neutral($0) })
            ], height: 150)
            Text("Carga combina duração e esforço de cada sessão. Sessões sem "
               + "frequência cardíaca ou esforço percebido entram apenas pela "
               + "duração.")
                .font(.caption)
                .foregroundStyle(Palette.inkMuted(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var intensityPanel: some View {
        let recent = workouts.filter {
            $0.start > Date().addingTimeInterval(-28 * 86_400)
        }
        var minutes: [IntensityZone: Double] = [:]
        for workout in recent {
            let zone = zoneFor(workout)
            minutes[zone, default: 0] += workout.durationMinutes
        }

        return VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Distribuição de intensidade",
                           subtitle: "Minutos por faixa nas últimas quatro semanas.")
            Panel {
                if recent.isEmpty {
                    Text(TrendAnalysis.insufficientData)
                        .font(.body)
                        .foregroundStyle(Palette.inkMuted(scheme))
                } else {
                    DistributionBars(items: IntensityZone.allCases.map { zone in
                        .init(id: zone.rawValue, label: zone.label,
                              value: minutes[zone] ?? 0, unitSuffix: "min")
                    })
                    Text("As faixas descrevem como o volume se distribuiu. "
                       + "Nenhuma delas é classificada como adequada ou "
                       + "inadequada pelo aplicativo.")
                        .font(.caption)
                        .foregroundStyle(Palette.inkMuted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Faixa a partir do esforço percebido ou da FC média disponível.
    private func zoneFor(_ workout: WorkoutSession) -> IntensityZone {
        if let rpe = workout.perceivedExertion {
            switch rpe {
            case ...3: return .light
            case 4...6: return .moderate
            case 7...8: return .vigorous
            default: return .high
            }
        }
        if let hr = workout.averageHeartRate {
            switch hr {
            case ..<110: return .light
            case 110..<140: return .moderate
            case 140..<165: return .vigorous
            default: return .high
            }
        }
        return .moderate
    }

    private var aerobicPanel: some View {
        let vo2 = Query.dailyValues(observations, kind: .vo2Max)
        let trend = Baseline.analyse(series: vo2, metricLabel: "VO₂ máximo",
                                     unit: MetricKind.vo2Max.unit, period: .d90,
                                     decimals: 1, directMeasurement: false)
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Capacidade aeróbica")
            Panel {
                TrendRow(trend: trend, showLimitations: false)
                if let last = vo2.first {
                    MetaTag(text: "Última leitura: "
                                + Format.dayMonth.string(from: last.day))
                }
                Text("Estimativas de VO₂ máximo variam conforme dispositivo, "
                   + "protocolo e qualidade do sinal. Servem para acompanhar "
                   + "tendência, não para avaliar condição cardiovascular "
                   + "individual.")
                    .font(.caption)
                    .foregroundStyle(Palette.inkMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var strengthPanel: some View {
        let calendar = Calendar(identifier: .iso8601)
        let recent = workouts.filter {
            $0.isStrengthTraining && $0.start > Date().addingTimeInterval(-28 * 86_400)
        }
        var perWeek: [Date: Int] = [:]
        for workout in recent {
            if let interval = calendar.dateInterval(of: .weekOfYear, for: workout.start) {
                perWeek[interval.start, default: 0] += 1
            }
        }
        let groups = Set(recent.compactMap(\.muscleGroups)).sorted()

        return VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Força")
            Panel {
                if recent.isEmpty {
                    Text("Nenhuma sessão de força registrada nas últimas quatro "
                       + "semanas.")
                        .font(.body)
                        .foregroundStyle(Palette.inkMuted(scheme))
                } else {
                    Text("\(recent.count) "
                       + (recent.count == 1 ? "sessão" : "sessões")
                       + " nas últimas quatro semanas.")
                        .font(.body)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                    if let average = Baseline.mean(perWeek.values.map(Double.init)) {
                        Text("Média de \(Format.decimal(average, 1)) por semana.")
                            .font(.subheadline)
                            .foregroundStyle(Palette.inkMuted(scheme))
                    }
                    if !groups.isEmpty {
                        FlowTags(tags: groups)
                    }
                }
            }
        }
    }

    private var sessionsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Sessões recentes")
            Panel {
                if workouts.isEmpty {
                    Text("Nenhuma sessão registrada.")
                        .font(.body)
                        .foregroundStyle(Palette.inkMuted(scheme))
                } else {
                    ForEach(workouts.prefix(12)) { workout in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(workout.activityType)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Palette.ink(scheme))
                                Spacer()
                                Text(Format.duration(minutes: workout.durationMinutes))
                                    .font(.subheadline)
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.inkSecondary(scheme))
                            }
                            HStack(spacing: 8) {
                                Text(Format.dayAndTime.string(from: workout.start))
                                Text("· \(workout.source.label)")
                                if let hr = workout.averageHeartRate {
                                    Text("· \(Format.decimal(hr, 0)) bpm")
                                }
                                if let distance = workout.distanceMeters, distance > 0 {
                                    Text("· \(Format.decimal(distance / 1000, 1)) km")
                                }
                            }
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Palette.inkMuted(scheme))
                        }
                        .padding(.vertical, 5)
                        .accessibilityElement(children: .combine)
                        if workout.id != workouts.prefix(12).last?.id {
                            Divider().overlay(Palette.hairline(scheme))
                        }
                    }
                }
            }
        }
    }
}
