import Foundation

/// Motor de scores — aberto de proposito.
///
/// WHOOP e Oura entregam um numero e escondem a formula. Aqui cada componente
/// devolve nota, peso e o motivo em texto, e a interface mostra tudo. Se voce
/// discorda de um peso, ele esta logo abaixo, editavel.
///
/// A baseline e SUA, nao populacional: cada metrica e comparada com a sua propria
/// media dos ultimos 30 dias. E por isso que os primeiros ~14 dias servem para
/// calibrar, e por isso o painel de qualidade existe.
enum ScoreEngine {

    struct Component: Identifiable, Hashable {
        let id: String
        let label: String
        let weight: Double
        let score: Int      // 0...100
        let detail: String
    }

    enum Band: String {
        case good, warning, serious, critical, unknown

        var label: String {
            switch self {
            case .good: return "Boa"
            case .warning: return "Moderada"
            case .serious: return "Baixa"
            case .critical: return "Muito baixa"
            case .unknown: return "Sem dados"
            }
        }
    }

    /// Quanto do score esta apoiado em dado real.
    enum Confidence: String {
        case high, medium, low

        var label: String {
            switch self {
            case .high: return "alta"
            case .medium: return "média"
            case .low: return "baixa"
            }
        }
    }

    struct Result {
        var recovery: Int?
        var components: [Component] = []
        var strain: Double?
        var band: Band = .unknown
        var confidence: Confidence = .low
    }

    // MARK: - Estatistica

    static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// Desvio padrao populacional. Zero quando ha um unico ponto.
    static func stdev(_ xs: [Double]) -> Double {
        guard xs.count > 1, let m = mean(xs) else { return 0 }
        let variance = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count)
        return variance.squareRoot()
    }

    static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 100) -> Double {
        min(max(x, lo), hi)
    }

    /// Baseline pessoal de uma metrica: media, desvio e quantos pontos existem.
    static func baseline(_ history: [DailyEntry],
                         _ keyPath: KeyPath<DailyEntry, Double?>,
                         days: Int = 30) -> (mean: Double, sd: Double, n: Int)? {
        let values = history.prefix(days).compactMap { $0[keyPath: keyPath] }
        guard let m = mean(values) else { return nil }
        return (m, stdev(values), values.count)
    }

    // MARK: - Recovery

    /// `history` deve estar ordenado do mais recente para o mais antigo e incluir
    /// o proprio dia avaliado.
    static func evaluate(day today: DailyEntry,
                         history: [DailyEntry],
                         sleepGoal: Double = 8.0) -> Result {
        var components: [Component] = []

        // Sono — proporcao da meta, saturando em 100.
        if let sh = today.sleepHours {
            let score = sleepGoal > 0 ? clamp(sh / sleepGoal * 100) : 0
            components.append(.init(
                id: "sleep", label: "Sono", weight: 0.30, score: Int(score.rounded()),
                detail: String(format: "%.1fh de %.0fh alvo", sh, sleepGoal)))
        }

        // FC de repouso — abaixo da sua baseline e bom, entao o z e invertido.
        if let rhr = today.restingHR, let b = baseline(history, \.restingHR) {
            let sd = b.sd > 0 ? b.sd : 3.0
            let z = (b.mean - rhr) / sd
            components.append(.init(
                id: "rhr", label: "FC repouso", weight: 0.25,
                score: Int(clamp(50 + z * 20).rounded()),
                detail: String(format: "%.0f bpm vs. base %.0f (n=%d)", rhr, b.mean, b.n)))
        }

        // HRV — acima da sua baseline e bom.
        if let hrv = today.hrv, let b = baseline(history, \.hrv) {
            let sd = b.sd > 0 ? b.sd : 8.0
            let z = (hrv - b.mean) / sd
            components.append(.init(
                id: "hrv", label: "HRV", weight: 0.25,
                score: Int(clamp(50 + z * 20).rounded()),
                detail: String(format: "%.0f ms vs. base %.0f (n=%d)", hrv, b.mean, b.n)))
        }

        // Subjetivo — o que nenhum sensor mede.
        var subjective: [Double] = []
        if let v = today.energy { subjective.append((v - 1) / 4 * 100) }
        if let v = today.stress { subjective.append((5 - v) / 4 * 100) }
        if let v = today.soreness { subjective.append((5 - v) / 4 * 100) }
        if let v = today.sleepQuality { subjective.append((v - 1) / 4 * 100) }
        if let m = mean(subjective) {
            components.append(.init(
                id: "subjective", label: "Subjetivo", weight: 0.20,
                score: Int(clamp(m).rounded()),
                detail: "energia, estresse, dor, qualidade do sono"))
        }

        var result = Result(components: components)

        // Media ponderada renormalizada: um dia incompleto nao vira score baixo,
        // vira score com confianca menor. A distincao importa.
        if !components.isEmpty {
            let weightSum = components.reduce(0) { $0 + $1.weight }
            let weighted = components.reduce(0.0) { $0 + Double($1.score) * $1.weight }
            let recovery = Int((weighted / weightSum).rounded())
            result.recovery = recovery
            result.band = band(for: recovery)
        }

        result.confidence = components.count >= 3 ? .high
            : (components.count == 2 ? .medium : .low)
        result.strain = strain(for: today)
        return result
    }

    static func band(for score: Int) -> Band {
        switch score {
        case 75...: return .good
        case 50..<75: return .warning
        case 30..<50: return .serious
        default: return .critical
        }
    }

    /// Strain do dia numa escala 0...21, no espirito do WHOOP: duracao vezes
    /// intensidade. Nao e TRIMP de verdade — TRIMP precisa de tempo em zonas de
    /// frequencia cardiaca, que so existe com FC continua durante o treino. Se a
    /// pulseira passar a entregar isso por BLE, da para trocar por TRIMP real.
    static func strain(for entry: DailyEntry) -> Double? {
        guard let minutes = entry.workoutMinutes, minutes > 0 else { return nil }
        let intensity = entry.workoutIntensity ?? 3.0
        let raw = (minutes / 120.0) * (intensity / 5.0) * 21.0
        return (min(raw, 21.0) * 10).rounded() / 10
    }

    /// Serie historica de recovery, recalculando cada dia so com a janela que
    /// existia ate ali — nada de baseline vindo do futuro.
    static func recoverySeries(_ history: [DailyEntry], sleepGoal: Double = 8.0)
        -> [(day: Date, value: Int)] {
        let ascending = history.reversed().map { $0 }
        var out: [(Date, Int)] = []
        for (i, entry) in ascending.enumerated() {
            let window = Array(ascending[0...i].reversed())
            if let r = evaluate(day: entry, history: window, sleepGoal: sleepGoal).recovery {
                out.append((entry.day, r))
            }
        }
        return out.map { (day: $0.0, value: $0.1) }
    }

    /// Media de uma metrica numa fatia, com o delta contra a fatia anterior.
    static func trend(_ history: [DailyEntry],
                      _ keyPath: KeyPath<DailyEntry, Double?>,
                      window: Int = 7) -> (value: Double?, delta: Double?) {
        let recent = mean(history.prefix(window).compactMap { $0[keyPath: keyPath] })
        let previous = mean(history.dropFirst(window).prefix(window)
            .compactMap { $0[keyPath: keyPath] })
        guard let recent else { return (nil, nil) }
        guard let previous else { return (recent, nil) }
        return (recent, recent - previous)
    }

    /// Dias consecutivos com registro, terminando hoje ou ontem.
    static func streak(_ history: [DailyEntry]) -> Int {
        let cal = Calendar.current
        let days = Set(history.map { cal.startOfDay(for: $0.day) })
        var cursor = cal.startOfDay(for: Date())
        if !days.contains(cursor) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: cursor),
                  days.contains(yesterday) else { return 0 }
            cursor = yesterday
        }
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }
}
