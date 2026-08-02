import Foundation

/// Janelas de comparação disponíveis.
enum TrendPeriod: String, CaseIterable, Identifiable, Sendable {
    case d7, d14, d30, d90

    var id: String { rawValue }

    var days: Int {
        switch self {
        case .d7: return 7
        case .d14: return 14
        case .d30: return 30
        case .d90: return 90
        }
    }

    var label: String { "\(days) dias" }
    var shortLabel: String { "\(days)d" }
}

/// Confiança de uma leitura. Declarada em toda conclusão; nunca implícita.
enum Confidence: String, Sendable {
    case high, moderate, low, notClinical

    var label: String {
        switch self {
        case .high: return "Alta"
        case .moderate: return "Moderada"
        case .low: return "Baixa"
        case .notClinical: return "Não utilizável clinicamente"
        }
    }

    /// Confiança suficiente para o aplicativo oferecer uma leitura de tendência.
    var supportsInterpretation: Bool {
        self == .high || self == .moderate
    }
}

/// Comparação de um valor atual contra a mediana pessoal de uma janela.
///
/// Usa mediana, não média: uma única noite atípica ou uma leitura de artefato
/// desloca a média e faz a comparação seguinte parecer uma mudança real.
struct TrendAnalysis {
    let metricLabel: String
    let unit: String
    let period: TrendPeriod
    let baseline: Double?
    let currentValue: Double?
    let sampleSize: Int
    let confidence: Confidence
    let limitations: [String]
    let decimals: Int
    /// Quando verdadeiro, valores acima do baseline são descritos como "acima"
    /// sem juízo de valor. A direção nunca implica bom ou ruim por si só.
    let higherLabel: String
    let lowerLabel: String

    static let associationNotice =
        "Associação no seu registro. Outros fatores podem explicar parte ou toda "
      + "a diferença observada."

    static let insufficientData =
        "Ainda não há dados suficientes para uma tendência confiável."

    var deltaAbsolute: Double? {
        guard let currentValue, let baseline else { return nil }
        return currentValue - baseline
    }

    var deltaPercent: Double? {
        guard let currentValue, let baseline, baseline != 0 else { return nil }
        return (currentValue - baseline) / baseline * 100
    }

    var direction: ChangeDirection {
        guard let delta = deltaAbsolute, let baseline, baseline != 0 else {
            return .unknown
        }
        // Uma variação abaixo de 5% da própria mediana é ruído para a maior
        // parte destas métricas e não é descrita como mudança.
        let relative = abs(delta) / abs(baseline)
        if relative < 0.05 { return .stable }
        return delta > 0 ? .above : .below
    }

    /// Frase descritiva, sem causalidade e sem juízo.
    var statement: String {
        guard confidence.supportsInterpretation,
              let current = currentValue, let base = baseline else {
            return TrendAnalysis.insufficientData
        }
        let currentText = Format.decimal(current, decimals)
        let baseText = Format.decimal(base, decimals)
        switch direction {
        case .above:
            return "\(currentText) \(unit) — \(higherLabel) da sua mediana de "
                 + "\(period.days) dias (\(baseText) \(unit))."
        case .below:
            return "\(currentText) \(unit) — \(lowerLabel) da sua mediana de "
                 + "\(period.days) dias (\(baseText) \(unit))."
        case .stable:
            return "\(currentText) \(unit) — próximo da sua mediana de "
                 + "\(period.days) dias (\(baseText) \(unit))."
        case .unknown:
            return TrendAnalysis.insufficientData
        }
    }
}

/// Cálculo de baseline pessoal e tendências.
enum Baseline {

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Confiança a partir da cobertura e do intervalo desde a última leitura.
    ///
    /// Cobertura alta com lacuna longa não sustenta comparar hoje: a mediana
    /// descreve um período que já passou.
    static func confidence(sampleSize: Int, expected: Int, gapDays: Int?,
                           directMeasurement: Bool) -> Confidence {
        guard sampleSize > 0 else { return .low }
        let coverage = Double(sampleSize) / Double(max(expected, 1))
        let gap = gapDays ?? 99

        if sampleSize >= 10 && coverage >= 0.6 && gap <= 2 {
            return directMeasurement ? .high : .moderate
        }
        if sampleSize >= 5 && gap <= 7 { return .moderate }
        return .low
    }

    /// Constrói a análise de uma série diária.
    ///
    /// `series` são pares dia/valor ordenados do mais recente para o mais antigo.
    static func analyse(series: [(day: Date, value: Double)],
                        metricLabel: String,
                        unit: String,
                        period: TrendPeriod,
                        decimals: Int = 0,
                        directMeasurement: Bool,
                        higherLabel: String = "acima",
                        lowerLabel: String = "abaixo",
                        extraLimitations: [String] = []) -> TrendAnalysis {

        let today = Calendar.current.startOfDay(for: Date())
        let cutoff = Calendar.current.date(byAdding: .day, value: -period.days,
                                           to: today) ?? today
        let window = series.filter { $0.day >= cutoff }
        let current = series.first?.value

        // O baseline exclui o valor de hoje: comparar um ponto contra uma
        // mediana que o contém achata a diferença.
        let historical = window.dropFirst().map(\.value)
        let base = median(historical)

        var gapDays: Int?
        if let latest = series.first?.day {
            gapDays = Calendar.current.dateComponents([.day], from: latest,
                                                      to: today).day
        }

        var limitations = extraLimitations
        if historical.count < 10 {
            limitations.append("Baseline com \(historical.count) observações na "
                             + "janela de \(period.days) dias.")
        }
        if let gap = gapDays, gap > 2 {
            limitations.append("A leitura mais recente tem \(gap) dias.")
        }
        if !directMeasurement {
            limitations.append("Valor derivado por aplicativo ou aparelho, não "
                             + "medido diretamente por instrumento validado.")
        }

        let conf = confidence(sampleSize: historical.count, expected: period.days,
                              gapDays: gapDays, directMeasurement: directMeasurement)

        return TrendAnalysis(
            metricLabel: metricLabel, unit: unit, period: period,
            baseline: base, currentValue: current, sampleSize: historical.count,
            confidence: conf, limitations: limitations, decimals: decimals,
            higherLabel: higherLabel, lowerLabel: lowerLabel)
    }
}
