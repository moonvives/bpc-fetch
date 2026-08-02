import Foundation
import SwiftData

// MARK: - Exames

/// Painéis de finalidade. Organizar por objetivo evita a lógica de "verificar
/// tudo" e mantém o acompanhamento junto de quem pediu o exame.
enum LabPanel: String, Codable, CaseIterable, Sendable {
    case cardiometabolic
    case organFunction
    case hematology
    case thyroid
    case contextual

    var label: String {
        switch self {
        case .cardiometabolic: return "Cardiometabólico"
        case .organFunction: return "Função orgânica"
        case .hematology: return "Hematológico"
        case .thyroid: return "Tireoide"
        case .contextual: return "Contextual"
        }
    }

    var purpose: String {
        switch self {
        case .cardiometabolic:
            return "Acompanha risco aterosclerótico e metabolismo de glicose ao "
                 + "longo do tempo."
        case .organFunction:
            return "Função renal e hepática."
        case .hematology:
            return "Série vermelha, branca e estoques de ferro."
        case .thyroid:
            return "Função tireoidiana, quando houver indicação clínica."
        case .contextual:
            return "Solicitados conforme sintomas, dieta, medicamentos ou "
                 + "avaliação profissional."
        }
    }
}

enum Biomarker: String, Codable, CaseIterable, Sendable {
    case totalCholesterol, ldl, hdl, triglycerides, nonHDL, apoB, lipoproteinA
    case fastingGlucose, hba1c
    case creatinine, egfr, ast, alt, ggt
    case hemoglobin, hematocrit, leukocytes, platelets, ferritin
    case tsh, freeT4
    case vitaminB12, vitaminD

    var label: String {
        switch self {
        case .totalCholesterol: return "Colesterol total"
        case .ldl: return "LDL-C"
        case .hdl: return "HDL-C"
        case .triglycerides: return "Triglicerídeos"
        case .nonHDL: return "Não-HDL"
        case .apoB: return "ApoB"
        case .lipoproteinA: return "Lipoproteína(a)"
        case .fastingGlucose: return "Glicemia de jejum"
        case .hba1c: return "Hemoglobina glicada"
        case .creatinine: return "Creatinina"
        case .egfr: return "Taxa de filtração glomerular"
        case .ast: return "AST"
        case .alt: return "ALT"
        case .ggt: return "GGT"
        case .hemoglobin: return "Hemoglobina"
        case .hematocrit: return "Hematócrito"
        case .leukocytes: return "Leucócitos"
        case .platelets: return "Plaquetas"
        case .ferritin: return "Ferritina"
        case .tsh: return "TSH"
        case .freeT4: return "T4 livre"
        case .vitaminB12: return "Vitamina B12"
        case .vitaminD: return "Vitamina D"
        }
    }

    var unit: String {
        switch self {
        case .totalCholesterol, .ldl, .hdl, .triglycerides, .nonHDL, .apoB,
             .fastingGlucose, .creatinine:
            return "mg/dL"
        case .lipoproteinA: return "nmol/L"
        case .hba1c: return "%"
        case .egfr: return "mL/min/1,73m²"
        case .ast, .alt, .ggt: return "U/L"
        case .hemoglobin: return "g/dL"
        case .hematocrit: return "%"
        case .leukocytes: return "/mm³"
        case .platelets: return "/mm³"
        case .ferritin: return "ng/mL"
        case .tsh: return "mUI/L"
        case .freeT4: return "ng/dL"
        case .vitaminB12: return "pg/mL"
        case .vitaminD: return "ng/mL"
        }
    }

    var panel: LabPanel {
        switch self {
        case .totalCholesterol, .ldl, .hdl, .triglycerides, .nonHDL, .apoB,
             .lipoproteinA, .fastingGlucose, .hba1c:
            return .cardiometabolic
        case .creatinine, .egfr, .ast, .alt, .ggt: return .organFunction
        case .hemoglobin, .hematocrit, .leukocytes, .platelets, .ferritin:
            return .hematology
        case .tsh, .freeT4: return .thyroid
        case .vitaminB12, .vitaminD: return .contextual
        }
    }

    /// Marcadores que compõem o acompanhamento cardiovascular prioritário.
    var isCardiovascularPriority: Bool {
        switch self {
        case .ldl, .apoB, .nonHDL, .hba1c, .fastingGlucose, .triglycerides:
            return true
        default: return false
        }
    }

    var decimals: Int {
        switch self {
        case .hba1c, .creatinine, .freeT4: return 2
        case .leukocytes, .platelets: return 0
        default: return 1
        }
    }
}

@Model
final class LabResult {
    var markerRaw: String
    var value: Double
    var collectedAt: Date
    var laboratory: String?
    /// Intervalo informado pelo próprio laboratório no laudo. O aplicativo não
    /// substitui esse intervalo por valores próprios.
    var referenceLow: Double?
    var referenceHigh: Double?
    var referenceText: String?
    var notes: String?
    var createdAt: Date

    var marker: Biomarker { Biomarker(rawValue: markerRaw) ?? .ldl }

    init(marker: Biomarker, value: Double, collectedAt: Date,
         laboratory: String? = nil, referenceLow: Double? = nil,
         referenceHigh: Double? = nil, referenceText: String? = nil) {
        self.markerRaw = marker.rawValue
        self.value = value
        self.collectedAt = collectedAt
        self.laboratory = laboratory
        self.referenceLow = referenceLow
        self.referenceHigh = referenceHigh
        self.referenceText = referenceText
        self.createdAt = Date()
    }

    /// Comparação com o intervalo do laudo. Não classifica doença e devolve nulo
    /// quando o laboratório não informou intervalo.
    enum ReferenceComparison {
        case within
        case below
        case above
        case noReference

        var label: String {
            switch self {
            case .within: return "Dentro do intervalo informado pelo laboratório"
            case .below: return "Abaixo do intervalo informado pelo laboratório"
            case .above: return "Acima do intervalo informado pelo laboratório"
            case .noReference: return "Sem intervalo de referência informado"
            }
        }
    }

    var comparison: ReferenceComparison {
        if let low = referenceLow, value < low { return .below }
        if let high = referenceHigh, value > high { return .above }
        if referenceLow == nil && referenceHigh == nil { return .noReference }
        return .within
    }

    static let outOfRangeGuidance =
        "Converse com seu médico, especialmente se houver sintomas, repetição do "
      + "achado ou fatores de risco."
}

// MARK: - Diário e contexto

enum ContextTag: String, Codable, CaseIterable, Sendable {
    case alcohol, caffeine, medication, lateMeal, illness, pain, stress
    case menstruation, intenseTraining, travel, heat

    var label: String {
        switch self {
        case .alcohol: return "Álcool"
        case .caffeine: return "Cafeína"
        case .medication: return "Medicação"
        case .lateMeal: return "Refeição tardia"
        case .illness: return "Doença ou sintomas"
        case .pain: return "Dor"
        case .stress: return "Estresse percebido"
        case .menstruation: return "Menstruação"
        case .intenseTraining: return "Treino intenso"
        case .travel: return "Viagem"
        case .heat: return "Calor"
        }
    }
}

@Model
final class DailyContextLog {
    var day: Date
    /// Tags cruas separadas por vírgula; SwiftData armazena melhor tipos simples.
    var tagsRaw: String
    var alcoholUnits: Double?
    var caffeineLastIntake: Date?
    var lateMealTime: Date?
    var perceivedStress: Int?     // 1...5
    var painLevel: Int?           // 0...10
    var note: String?
    var updatedAt: Date

    var tags: [ContextTag] {
        get { tagsRaw.split(separator: ",").compactMap { ContextTag(rawValue: String($0)) } }
        set { tagsRaw = newValue.map(\.rawValue).joined(separator: ",") }
    }

    init(day: Date) {
        self.day = Calendar.current.startOfDay(for: day)
        self.tagsRaw = ""
        self.updatedAt = Date()
    }
}

/// Registro de medicação como contexto temporal. O aplicativo nunca sugere
/// iniciar, interromper, pular, compensar ou ajustar dose.
@Model
final class MedicationContextLog {
    var name: String
    var takenAt: Date
    var note: String?

    init(name: String, takenAt: Date, note: String? = nil) {
        self.name = name
        self.takenAt = takenAt
        self.note = note
    }

    static let notice =
        "Este aplicativo não indica iniciar, interromper, pular, compensar ou "
      + "ajustar doses. Leve os registros ao profissional que acompanha sua "
      + "prescrição."
}

@Model
final class SymptomLog {
    var recordedAt: Date
    var descriptionText: String
    var severity: Int?   // 1...5
    var note: String?

    init(recordedAt: Date, descriptionText: String, severity: Int? = nil) {
        self.recordedAt = recordedAt
        self.descriptionText = descriptionText
        self.severity = severity
    }
}
