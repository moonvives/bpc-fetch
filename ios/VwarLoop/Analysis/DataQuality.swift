import Foundation

/// Relatório de qualidade por métrica. Aparece antes de qualquer interpretação.
struct DataQualityReport: Identifiable {
    let id: String
    let metricLabel: String
    let source: HealthSource?
    let sourceName: String
    let observations: Int
    let coverageDays: Int
    let periodDays: Int
    let lastReading: Date?
    let duplicatesDetected: Int
    let largestGapDays: Int?
    let isDirect: Bool
    let confidence: Confidence
    /// Frase pronta explicando por que a confiança é essa.
    let rationale: String

    var coverageFraction: Double {
        periodDays > 0 ? Double(coverageDays) / Double(periodDays) : 0
    }

    var sourceLabel: String {
        if !sourceName.isEmpty { return sourceName }
        return source?.label ?? "Sem fonte identificada"
    }
}

enum DataQuality {

    /// Métricas que este aplicativo nunca usa para interpretação clínica.
    ///
    /// Estimativas ópticas de pulso para glicose, pressão arterial, lipídios e
    /// ácido úrico não são medidas do analito. Ficam fora de scores, tendências,
    /// recomendações e de qualquer texto do assistente.
    struct ExcludedMetric: Identifiable {
        let id: String
        let label: String
        let reason: String
    }

    static let excluded: [ExcludedMetric] = [
        .init(id: "glucose_wearable", label: "Glicose por dispositivo vestível",
              reason: "Estimativa por sensor óptico, sem validação para decisão "
                    + "clínica. Use glicemia de jejum ou hemoglobina glicada de "
                    + "laboratório."),
        .init(id: "bp_optical", label: "Pressão arterial por sensor de pulso",
              reason: "Somente medidas de manguito de braço entram na análise de "
                    + "pressão."),
        .init(id: "lipids_wearable", label: "Lipídios por dispositivo vestível",
              reason: "Não corresponde a dosagem laboratorial. Use lipidograma."),
        .init(id: "uric_wearable", label: "Ácido úrico por dispositivo vestível",
              reason: "Não corresponde a dosagem laboratorial."),
    ]

    static let excludedNotice = "Excluída de interpretações e recomendações."

    /// Monta o relatório de uma série de observações diárias.
    static func report(id: String,
                       metricLabel: String,
                       days: [Date],
                       periodDays: Int,
                       source: HealthSource?,
                       sourceName: String,
                       isDirect: Bool,
                       extraRationale: String? = nil) -> DataQualityReport {

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let cutoff = calendar.date(byAdding: .day, value: -periodDays, to: today) ?? today

        let normalized = days.map { calendar.startOfDay(for: $0) }.filter { $0 >= cutoff }
        let unique = Set(normalized)
        let duplicates = normalized.count - unique.count
        let sorted = unique.sorted(by: >)
        let last = sorted.first

        var largestGap: Int?
        if sorted.count > 1 {
            var maxGap = 0
            for i in 0..<(sorted.count - 1) {
                let gap = calendar.dateComponents([.day], from: sorted[i + 1],
                                                  to: sorted[i]).day ?? 0
                maxGap = max(maxGap, gap)
            }
            largestGap = maxGap
        }

        var gapToToday: Int?
        if let last {
            gapToToday = calendar.dateComponents([.day], from: last, to: today).day
        }

        let confidence: Confidence = Baseline.confidence(
            sampleSize: unique.count, expected: periodDays,
            gapDays: gapToToday, directMeasurement: isDirect)

        var rationale: String
        switch confidence {
        case .high:
            rationale = "Medida direta, fonte identificada e cobertura adequada "
                      + "no período."
        case .moderate:
            rationale = isDirect
                ? "Medida direta com cobertura incompleta no período."
                : "Valor derivado por aplicativo ou aparelho; cobertura razoável, "
                + "mas sem contexto suficiente de postura e movimento."
        case .low:
            rationale = "Poucas observações, origem limitada ou lacuna grande no "
                      + "período."
        case .notClinical:
            rationale = "Estimativa não validada para decisão clínica."
        }
        if let extraRationale { rationale += " " + extraRationale }

        return DataQualityReport(
            id: id, metricLabel: metricLabel, source: source,
            sourceName: sourceName, observations: normalized.count,
            coverageDays: unique.count, periodDays: periodDays,
            lastReading: last, duplicatesDetected: duplicates,
            largestGapDays: largestGap, isDirect: isDirect,
            confidence: confidence, rationale: rationale)
    }
}

/// Disponibilidade de dados de um eixo. Descreve o que existe para analisar,
/// não o estado do corpo.
enum DataAvailability: String {
    case complete, partial, insufficient

    var label: String {
        switch self {
        case .complete: return "Completa"
        case .partial: return "Parcial"
        case .insufficient: return "Insuficiente"
        }
    }

    static func from(present: Int, total: Int) -> DataAvailability {
        guard total > 0 else { return .insufficient }
        let fraction = Double(present) / Double(total)
        if fraction >= 0.75 { return .complete }
        if fraction >= 0.35 { return .partial }
        return .insufficient
    }
}
