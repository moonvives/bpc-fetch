import Charts
import SwiftUI

/// Tela principal: Recovery com o detalhamento aberto, blocos de estatistica e
/// tendencias.
///
/// A diferenca deliberada em relacao ao WHOOP e que a formula fica visivel. Cada
/// componente mostra a nota, o peso e o motivo, e o rodape diz em quantos
/// componentes o score se apoia.
struct TodayView: View {
    let entries: [DailyEntry]
    let sleepGoal: Double

    private var today: DailyEntry? {
        let day = Calendar.current.startOfDay(for: Date())
        return entries.first { $0.day == day }
    }

    private var result: ScoreEngine.Result {
        guard let today else { return .init() }
        return ScoreEngine.evaluate(day: today, history: entries, sleepGoal: sleepGoal)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    heroCard
                    SectionLabel(text: "Últimos 7 dias").padding(.top, 8)
                    tiles
                    SectionLabel(text: "Tendências").padding(.top, 8)
                    charts
                    disclaimer
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("VWAR Loop")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var heroCard: some View {
        Card {
            HStack(alignment: .top, spacing: 18) {
                RecoveryRing(score: result.recovery, band: result.band)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            if result.components.isEmpty {
                Text("Sem check-in de hoje. Abra a aba Check-in para registrar.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            } else {
                HStack(spacing: 6) {
                    Text("Confiança do score:").foregroundStyle(Theme.muted)
                    Text(result.confidence.label).foregroundStyle(Theme.ink).bold()
                    if let strain = result.strain {
                        Text("·").foregroundStyle(Theme.muted)
                        Text("Strain").foregroundStyle(Theme.muted)
                        Text(String(format: "%.1f/21", strain))
                            .foregroundStyle(Theme.ink).bold()
                    }
                }
                .font(.caption)

                ForEach(result.components) { component in
                    ComponentRow(component: component)
                }

                Text("O score é a média ponderada dos componentes acima, "
                   + "renormalizada sobre o que existe — um dia incompleto reduz "
                   + "a confiança, não a nota.")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 2)
            }
        }
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                            GridItem(.flexible(), spacing: 14)], spacing: 14) {
            let rhr = ScoreEngine.trend(entries, \.restingHR)
            let hrv = ScoreEngine.trend(entries, \.hrv)
            let sleep = ScoreEngine.trend(entries, \.sleepHours)
            let spo2 = ScoreEngine.trend(entries, \.spo2)

            StatTile(label: "FC repouso", value: rhr.value, unit: "bpm",
                     delta: rhr.delta, lowerIsBetter: true)
            StatTile(label: "HRV", value: hrv.value, unit: "ms", delta: hrv.delta)
            StatTile(label: "Sono", value: sleep.value, unit: "h",
                     decimals: 1, delta: sleep.delta)
            StatTile(label: "SpO2", value: spo2.value, unit: "%", delta: spo2.delta)
        }
    }

    private var charts: some View {
        VStack(spacing: 14) {
            let recovery = ScoreEngine.recoverySeries(entries, sleepGoal: sleepGoal)
                .map { TrendPoint(day: $0.day, value: Double($0.value)) }
            TrendChart(title: "Recovery", subtitle: "score diário (0–100)",
                       points: recovery, color: Theme.accent, decimals: 0)

            TrendChart(title: "HRV", subtitle: "RMSSD, ms",
                       points: points(\.hrv), color: Theme.aqua, decimals: 0)

            TrendChart(title: "FC de repouso", subtitle: "batimentos por minuto",
                       points: points(\.restingHR), color: Theme.yellow, decimals: 0)

            TrendChart(title: "Sono", subtitle: "horas por noite",
                       points: points(\.sleepHours), color: Theme.violet, decimals: 1)
        }
    }

    private func points(_ keyPath: KeyPath<DailyEntry, Double?>) -> [TrendPoint] {
        entries.reversed().compactMap { entry in
            entry[keyPath: keyPath].map { TrendPoint(day: entry.day, value: $0) }
        }
        .suffix(90)
        .map { $0 }
    }

    private var disclaimer: some View {
        Text("App de bem-estar, não dispositivo médico. FC, HRV, SpO2, sono e "
           + "passos são tendências. " + UnvalidatedMetrics.explanation)
            .font(.caption2)
            .foregroundStyle(Theme.muted)
            .padding(.top, 10)
    }
}

private struct ComponentRow: View {
    let component: ScoreEngine.Component

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(component.label)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text("peso \(Int(component.weight * 100))%")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                Text("\(component.score)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .frame(width: 34, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(Theme.accent)
                        .frame(width: geo.size.width * CGFloat(component.score) / 100)
                }
            }
            .frame(height: 6)
            Text(component.detail)
                .font(.caption2)
                .foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 3)
    }
}

struct TrendPoint: Identifiable {
    var id: Date { day }
    let day: Date
    let value: Double
}

/// Grafico de linha com marcador de seleção ao arrastar.
struct TrendChart: View {
    let title: String
    let subtitle: String
    let points: [TrendPoint]
    let color: Color
    var decimals: Int = 0

    @State private var selected: TrendPoint?

    var body: some View {
        Card {
            Text(title).font(.headline).foregroundStyle(Theme.ink)

            if let selected {
                Text(selected.day.formatted(.dateTime.day().month(.abbreviated))
                     + " · " + String(format: "%.\(decimals)f", selected.value))
                    .font(.caption).foregroundStyle(Theme.inkSecondary)
            } else {
                Text(subtitle).font(.caption).foregroundStyle(Theme.muted)
            }

            if points.count < 2 {
                Text("Dados insuficientes ainda")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("Dia", point.day),
                                 y: .value(title, point.value))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round,
                                                   lineJoin: .round))
                            .interpolationMethod(.monotone)
                    }
                    if let selected {
                        RuleMark(x: .value("Dia", selected.day))
                            .foregroundStyle(Theme.axis)
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(x: .value("Dia", selected.day),
                                  y: .value(title, selected.value))
                            .foregroundStyle(color)
                            .symbolSize(90)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisGridLine().foregroundStyle(Theme.line)
                        AxisValueLabel().foregroundStyle(Theme.muted)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                        AxisGridLine().foregroundStyle(Theme.line)
                        AxisValueLabel().foregroundStyle(Theme.muted)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { drag in
                                        guard let plotFrame = proxy.plotFrame else { return }
                                        let x = drag.location.x - geo[plotFrame].origin.x
                                        guard let date: Date = proxy.value(atX: x) else { return }
                                        selected = points.min {
                                            abs($0.day.timeIntervalSince(date))
                                                < abs($1.day.timeIntervalSince(date))
                                        }
                                    }
                                    .onEnded { _ in selected = nil }
                            )
                    }
                }
                .frame(height: 150)
            }
        }
    }
}
