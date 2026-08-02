import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DailyEntry.day, order: .reverse) private var entries: [DailyEntry]

    @StateObject private var health = HealthKitBridge()
    @StateObject private var band = BandManager()
    @AppStorage("sleepGoal") private var sleepGoal = 8.0

    var body: some View {
        TabView {
            TodayView(entries: entries, sleepGoal: sleepGoal)
                .tabItem { Label("Hoje", systemImage: "circle.dashed") }

            CheckInView(entries: entries, band: band)
                .tabItem { Label("Check-in", systemImage: "square.and.pencil") }

            CoachView(entries: entries, sleepGoal: sleepGoal)
                .tabItem { Label("Coach", systemImage: "text.bubble") }

            DataQualityView(entries: entries, health: health, band: band,
                            sleepGoal: $sleepGoal)
                .tabItem { Label("Dados", systemImage: "chart.bar.doc.horizontal") }
        }
        .background(Theme.bg)
    }
}

/// Utilitarios compartilhados entre as telas.
enum EntryStore {

    /// Devolve o registro do dia, criando se ainda nao existe.
    static func entry(for day: Date, in context: ModelContext,
                      existing: [DailyEntry]) -> DailyEntry {
        let normalized = Calendar.current.startOfDay(for: day)
        if let found = existing.first(where: { $0.day == normalized }) {
            return found
        }
        let created = DailyEntry(day: normalized)
        context.insert(created)
        return created
    }

    /// Monta o texto que vai no prompt do coach: numeros + incerteza.
    ///
    /// A incerteza vem junto de proposito. Um resumo so com medias faz o modelo
    /// falar com a mesma confianca sobre uma metrica com 28 dias de historico e
    /// sobre outra com 2.
    static func coachContext(_ entries: [DailyEntry], sleepGoal: Double) -> String {
        var lines: [String] = []
        let today = Calendar.current.startOfDay(for: Date())

        if let todayEntry = entries.first(where: { $0.day == today }) {
            let result = ScoreEngine.evaluate(day: todayEntry, history: entries,
                                              sleepGoal: sleepGoal)
            if let recovery = result.recovery {
                lines.append("Recovery de hoje: \(recovery)/100 "
                    + "(\(result.band.label), confiança \(result.confidence.label)).")
                for component in result.components {
                    lines.append("  - \(component.label): \(component.score)/100 "
                        + "(\(component.detail)).")
                }
            }
            if let strain = result.strain {
                lines.append(String(format: "Strain de hoje: %.1f/21.", strain))
            }
        } else {
            lines.append("Ainda não há check-in de hoje.")
        }

        lines.append("Sequência de check-ins: \(ScoreEngine.streak(entries)) dias.")

        lines.append("\nIncerteza por métrica (cobertura/30d, lacuna, baseline):")
        for metric in Provenance.evaluate(entries) {
            lines.append("  - " + metric.promptLine)
        }

        lines.append("\nMédias de 7 dias:")
        let trends: [(String, KeyPath<DailyEntry, Double?>, Int)] = [
            ("Sono (h)", \.sleepHours, 1), ("FC repouso (bpm)", \.restingHR, 0),
            ("HRV (ms)", \.hrv, 0), ("SpO2 (%)", \.spo2, 0),
        ]
        for (label, keyPath, decimals) in trends {
            let t = ScoreEngine.trend(entries, keyPath)
            guard let value = t.value else { continue }
            var line = String(format: "  - %@: %.\(decimals)f", label, value)
            if let delta = t.delta {
                line += String(format: " (Δ7d %+.\(decimals)f)", delta)
            }
            lines.append(line)
        }

        lines.append("\nÚltimos dias (mais recente primeiro):")
        let formatter = EntryDTO.dayFormatter
        for entry in entries.prefix(14) {
            var parts = [formatter.string(from: entry.day)]
            let fields: [(String, Double?)] = [
                ("sono", entry.sleepHours), ("rhr", entry.restingHR),
                ("hrv", entry.hrv), ("treino_min", entry.workoutMinutes),
                ("energia", entry.energy), ("estresse", entry.stress),
                ("foco", entry.focus),
            ]
            for (name, value) in fields {
                if let value { parts.append("\(name)=\(formatted(value))") }
            }
            if let type = entry.workoutType, !type.isEmpty {
                parts.append("treino=\(type)")
            }
            if let notes = entry.notes, !notes.isEmpty {
                parts.append("nota=\"\(notes.prefix(80))\"")
            }
            lines.append("  " + parts.joined(separator: ", "))
        }

        return lines.joined(separator: "\n")
    }

    private static func formatted(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}
