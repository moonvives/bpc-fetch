import Foundation

/// Painel de proveniencia e incerteza.
///
/// A parte dificil nao e ler a Saude da Apple. E mostrar a incerteza ANTES de
/// qualquer conclusao: de onde veio, quantos dias tem, ha quanto tempo foi a
/// ultima medida, ja existe baseline. Sem isso, um sinal ruidoso parece mais
/// preciso do que e — e uma IA em cima dele produz narrativa confiante sobre
/// nada.
///
/// Este tipo alimenta a tela de Qualidade dos Dados e vai junto no prompt do
/// coach, para que ele calibre o quanto afirma.
enum Provenance {

    enum Quality: String {
        case reliable, partial, sparse, missing

        var label: String {
            switch self {
            case .reliable: return "Confiável"
            case .partial: return "Parcial"
            case .sparse: return "Escasso"
            case .missing: return "Sem dados"
            }
        }
    }

    struct Metric: Identifiable {
        let id: String
        let label: String
        let coverage30d: Int      // dias com valor nos ultimos 30
        let gapDays: Int?         // dias desde a ultima medida
        let baselineN: Int        // pontos disponiveis para a baseline
        let source: DataSource
        let quality: Quality

        var hasBaseline: Bool { baselineN >= 14 }

        /// Uma linha para o prompt do coach.
        var promptLine: String {
            let gap = gapDays.map { "\($0)d" } ?? "—"
            return "\(label): \(coverage30d)/30 dias, lacuna \(gap), "
                + "baseline=\(hasBaseline ? "sim" : "não") (\(quality.label.lowercased()))"
        }
    }

    private struct Spec {
        let id: String
        let label: String
        let keyPath: KeyPath<DailyEntry, Double?>
    }

    private static let specs: [Spec] = [
        .init(id: "resting_hr", label: "FC repouso", keyPath: \.restingHR),
        .init(id: "hrv", label: "HRV", keyPath: \.hrv),
        .init(id: "sleep_hours", label: "Sono", keyPath: \.sleepHours),
        .init(id: "spo2", label: "SpO2", keyPath: \.spo2),
        .init(id: "temperature", label: "Temperatura", keyPath: \.bodyTemperature),
    ]

    /// `history` ordenado do mais recente para o mais antigo.
    static func evaluate(_ history: [DailyEntry]) -> [Metric] {
        let today = Calendar.current.startOfDay(for: Date())
        let window = Array(history.prefix(30))

        return specs.map { spec in
            let coverage = window.filter { $0[keyPath: spec.keyPath] != nil }.count

            // Dias desde a ultima vez que a metrica apareceu.
            var gap: Int?
            var lastSource: DataSource = .manual
            for entry in history where entry[keyPath: spec.keyPath] != nil {
                gap = Calendar.current.dateComponents(
                    [.day], from: entry.day, to: today).day
                lastSource = entry.source
                break
            }

            let n = ScoreEngine.baseline(history, spec.keyPath)?.n ?? 0

            // Uma metrica so e "confiavel" com baseline formada E recente.
            // Cobertura alta com lacuna de duas semanas nao serve para comparar
            // o dia de hoje contra nada.
            let quality: Quality
            if coverage == 0 {
                quality = .missing
            } else if n >= 14 && (gap ?? 99) <= 2 {
                quality = .reliable
            } else if coverage >= 5 {
                quality = .partial
            } else {
                quality = .sparse
            }

            return Metric(id: spec.id, label: spec.label, coverage30d: coverage,
                          gapDays: gap, baselineN: n, source: lastSource,
                          quality: quality)
        }
    }
}

/// Metricas que este app se recusa a tratar como medicao.
///
/// A VWAR anuncia acido urico, lipidios, glicose e pressao arterial. O chipset e
/// um JieLi JL7013A com sensor optico (PPG) e eletrodos de ECG — nao existe
/// sensor bioquimico ali. Esses numeros sao saida de algoritmo, nao leitura de
/// analito.
///
/// A FDA emitiu alerta formal em 21/02/2024 contra wearables que afirmam medir
/// parametros sanguineos sem furar a pele. A propria VWAR declara na ficha que o
/// produto nao e dispositivo medico.
///
/// Consequencia pratica no codigo: se um desses valores chegar pela Saude da
/// Apple (o G Band escreve glicose la), ele e exibido com rotulo de estimativa e
/// fica fora de todo score, tendencia e prompt do coach.
enum UnvalidatedMetrics {
    static let names = ["ácido úrico", "lipídios", "colesterol", "glicose",
                        "pressão arterial"]

    static let explanation = """
        A pulseira estima estes valores por software a partir do sensor óptico. \
        Não há sensor bioquímico no aparelho e não há validação clínica. Ficam \
        fora dos scores e fora da análise do coach. Para estes marcadores, exame \
        laboratorial; para pressão, aparelho de braço validado pelo Inmetro.
        """
}
