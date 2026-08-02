import Foundation

/// Insight em formato fixo. Um insight só é gerado quando existe métrica válida,
/// janela clara, baseline suficiente e confiança declarada.
struct Insight: Identifiable {
    let id: String
    let title: String
    let observed: String
    let comparison: String
    let related: String?
    let limitations: String
    let nextStep: String
    let confidence: Confidence

    static let sectionTitles = (
        observed: "Dado observado",
        comparison: "Comparação",
        related: "O que pode estar relacionado",
        limitations: "Limitações",
        nextStep: "Próximo passo"
    )
}

/// Aviso de segurança. Sintomas orientam conduta independentemente de qualquer
/// número do aplicativo.
enum SafetyNotice {

    static let headline =
        "Dados de dispositivos ajudam a acompanhar tendências, mas sintomas "
      + "importantes precisam de avaliação médica independentemente de qualquer "
      + "indicador."

    static let urgentSymptoms = [
        "Dor ou pressão no peito.",
        "Falta de ar importante em repouso.",
        "Desmaio ou quase-desmaio.",
        "Palpitação intensa, persistente ou percebida como irregular.",
        "Fraqueza ou alteração neurológica súbita.",
        "Confusão.",
        "Piora rápida do estado geral.",
        "Pressão muito elevada acompanhada de sintomas preocupantes.",
    ]

    static let repeatMeasureGuidance =
        "Se uma medida vier muito diferente do seu padrão, repita-a com técnica "
      + "correta. Se persistir, ou se houver sintomas, busque orientação "
      + "profissional."

    static let medicationNotice = MedicationContextLog.notice
}

/// Geração de insights a partir das séries já analisadas.
enum InsightBuilder {

    /// Sono abaixo ou acima da tendência.
    static func sleepDuration(trend: TrendAnalysis,
                              contextTags: [ContextTag],
                              hrvAvailable: Bool) -> Insight? {
        guard trend.confidence.supportsInterpretation,
              let current = trend.currentValue,
              let base = trend.baseline else { return nil }

        let deltaMinutes = current - base
        guard abs(deltaMinutes) >= 30 else { return nil }

        let below = deltaMinutes < 0
        let title = below
            ? "Duração do sono abaixo da sua tendência"
            : "Duração do sono acima da sua tendência"

        let observed = "Você dormiu \(Format.duration(minutes: current)) na última "
                     + "noite."
        let comparison = "Isto ficou \(Format.duration(minutes: abs(deltaMinutes))) "
                       + (below ? "abaixo" : "acima")
                       + " da sua mediana dos últimos \(trend.period.days) dias."

        var related: String?
        let relevant = contextTags.filter {
            [.caffeine, .alcohol, .lateMeal, .stress, .intenseTraining, .travel,
             .heat, .illness, .pain].contains($0)
        }
        if !relevant.isEmpty {
            let names = relevant.map(\.label).joined(separator: ", ")
            related = "Você registrou: \(names). Esses registros podem contribuir, "
                    + "mas não comprovam a causa."
        }

        var limitations = trend.limitations
        if !hrvAvailable {
            limitations.append("Não houve variabilidade da frequência cardíaca "
                             + "disponível nesta noite.")
        }

        let nextStep = below
            ? "Se fizer sentido para sua rotina, observe o sono nas próximas duas "
            + "semanas em noites com e sem os registros acima."
            : "Continue observando o padrão ao longo das próximas duas semanas."

        return Insight(
            id: "sleep_duration", title: title, observed: observed,
            comparison: comparison, related: related,
            limitations: limitations.joined(separator: " "),
            nextStep: nextStep, confidence: trend.confidence)
    }

    /// Frequência cardíaca durante o sono fora da faixa recente.
    static func sleepingHeartRate(trend: TrendAnalysis,
                                  contextTags: [ContextTag]) -> Insight? {
        guard trend.confidence.supportsInterpretation,
              let current = trend.currentValue,
              let base = trend.baseline else { return nil }

        let delta = current - base
        guard abs(delta) >= 3 else { return nil }

        let title = delta > 0
            ? "Frequência cardíaca noturna acima da sua faixa recente"
            : "Frequência cardíaca noturna abaixo da sua faixa recente"

        let observed = "A média durante o sono foi \(Format.decimal(current, 0)) bpm."
        let comparison = "Isto ficou \(Format.signed(delta, 0, unit: "bpm")) versus "
                       + "sua mediana de \(trend.period.days) dias "
                       + "(\(Format.decimal(base, 0)) bpm)."

        var related: String?
        let relevant = contextTags.filter {
            [.alcohol, .intenseTraining, .illness, .heat, .stress, .lateMeal,
             .medication].contains($0)
        }
        if !relevant.isEmpty {
            related = "Registros do período: "
                    + relevant.map(\.label).joined(separator: ", ")
                    + ". São contexto, não explicação confirmada."
        }

        return Insight(
            id: "sleeping_hr", title: title, observed: observed,
            comparison: comparison, related: related,
            limitations: trend.limitations.joined(separator: " "),
            nextStep: "Acompanhe pelas próximas noites. Se houver sintomas, "
                    + "procure orientação profissional.",
            confidence: trend.confidence)
    }

    /// Volume de treino da semana comparado às quatro semanas anteriores.
    static func trainingLoad(currentWeek: Double, priorAverage: Double,
                             sessionCount: Int, sampleWeeks: Int) -> Insight? {
        guard priorAverage > 0, sampleWeeks >= 2 else { return nil }
        let deltaPercent = (currentWeek - priorAverage) / priorAverage * 100
        guard abs(deltaPercent) >= 15 else { return nil }

        let above = deltaPercent > 0
        let title = above
            ? "Carga da semana acima da sua média recente"
            : "Carga da semana abaixo da sua média recente"

        let observed = "Você registrou \(sessionCount) "
                     + (sessionCount == 1 ? "sessão" : "sessões") + " nesta semana."
        let comparison = "O volume ficou \(Format.signed(deltaPercent, 0, unit: "%")) "
                       + "versus a média das \(sampleWeeks) semanas anteriores."

        let nextStep = above
            ? "Considere progressão gradual e atenção a dor persistente, fadiga "
            + "incomum e queda importante de desempenho."
            : "Se estiver bem e sem contraindicação, uma sessão leve ou moderada "
            + "pode ajudar a manter consistência."

        return Insight(
            id: "training_load", title: title, observed: observed,
            comparison: comparison,
            related: nil,
            limitations: "A carga usa duração e esforço registrados. Sessões sem "
                       + "frequência cardíaca ou esforço percebido entram apenas "
                       + "pela duração.",
            nextStep: nextStep, confidence: sampleWeeks >= 4 ? .moderate : .low)
    }

    /// Aderência ao protocolo matinal de pressão.
    static func bloodPressureAdherence(sessionsLast14: Int,
                                       targetPerWeek: Int) -> Insight? {
        let expected = targetPerWeek * 2
        guard expected > 0 else { return nil }

        let title = "Sessões matinais de pressão nas últimas duas semanas"
        let observed = "Há \(sessionsLast14) "
                     + (sessionsLast14 == 1 ? "sessão completa" : "sessões completas")
                     + " no período."
        let comparison = "Sua meta atual é \(targetPerWeek) por semana, o que "
                       + "corresponde a \(expected) no período."

        let nextStep = sessionsLast14 >= expected
            ? "Mantendo esta frequência, a tendência de \(TrendPeriod.d30.label) "
            + "fica com base suficiente."
            : "Uma sessão a mais por semana deixa a tendência mensal mais estável."

        return Insight(
            id: "bp_adherence", title: title, observed: observed,
            comparison: comparison, related: nil,
            limitations: "Somente sessões padronizadas entram na tendência. "
                       + "Leituras avulsas ficam registradas, mas não formam "
                       + "a média de referência.",
            nextStep: nextStep,
            confidence: sessionsLast14 >= 4 ? .moderate : .low)
    }
}
