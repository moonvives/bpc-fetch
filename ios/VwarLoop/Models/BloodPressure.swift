import Foundation
import SwiftData

/// Braço usado na medida. Diferenças entre braços são comuns; registrar permite
/// comparar leituras equivalentes.
enum CuffArm: String, Codable, CaseIterable, Sendable {
    case left, right, unspecified

    var label: String {
        switch self {
        case .left: return "Braço esquerdo"
        case .right: return "Braço direito"
        case .unspecified: return "Não informado"
        }
    }
}

enum ReadingValidity: String, Codable, Sendable {
    case valid
    case outOfProtocol      // fora das condições padronizadas
    case discarded          // descartada pela pessoa

    var label: String {
        switch self {
        case .valid: return "Válida"
        case .outOfProtocol: return "Fora do protocolo"
        case .discarded: return "Descartada"
        }
    }
}

@Model
final class BloodPressureReading {
    var timestamp: Date
    var systolic: Int
    var diastolic: Int
    var pulse: Int?
    var sourceRaw: String
    var armRaw: String
    var cuffModel: String?
    /// Posição dentro do protocolo de três medidas: 1, 2 ou 3. Nulo em leitura
    /// avulsa.
    var protocolStep: Int?
    var notes: String?
    var validityRaw: String
    var sessionID: UUID?

    var source: HealthSource { HealthSource(rawValue: sourceRaw) ?? .cuff }
    var arm: CuffArm { CuffArm(rawValue: armRaw) ?? .unspecified }
    var validity: ReadingValidity { ReadingValidity(rawValue: validityRaw) ?? .valid }
    var day: Date { Calendar.current.startOfDay(for: timestamp) }

    init(timestamp: Date, systolic: Int, diastolic: Int, pulse: Int? = nil,
         source: HealthSource = .cuff, arm: CuffArm = .unspecified,
         cuffModel: String? = nil, protocolStep: Int? = nil,
         validity: ReadingValidity = .valid, sessionID: UUID? = nil) {
        self.timestamp = timestamp
        self.systolic = systolic
        self.diastolic = diastolic
        self.pulse = pulse
        self.sourceRaw = source.rawValue
        self.armRaw = arm.rawValue
        self.cuffModel = cuffModel
        self.protocolStep = protocolStep
        self.validityRaw = validity.rawValue
        self.sessionID = sessionID
    }
}

enum BPSessionType: String, Codable, CaseIterable, Sendable {
    case morningReference
    case nightContext
    case adHoc

    var label: String {
        switch self {
        case .morningReference: return "Medição matinal de referência"
        case .nightContext: return "Leitura noturna contextual"
        case .adHoc: return "Leitura avulsa"
        }
    }

    var summary: String {
        switch self {
        case .morningReference:
            return "Três medidas em repouso, antes de comer, treinar ou usar "
                 + "estimulantes. É a base para acompanhar tendência."
        case .nightContext:
            return "Acompanha como o dia se refletiu na sua pressão. Não "
                 + "substitui a média matinal padronizada para análise de tendência."
        case .adHoc:
            return "Leitura fora de horário padronizado."
        }
    }
}

@Model
final class BloodPressureSession {
    var id: UUID
    var date: Date
    var typeRaw: String
    var averageSystolic: Double
    var averageDiastolic: Double
    var averagePulse: Double?
    /// Fração das etapas do protocolo cumpridas, de 0 a 1.
    var adherence: Double
    var notes: String?
    var sourceRaw: String
    var createdAt: Date

    // Contexto opcional informado na hora da sessão.
    var contextSleepPoor: Bool
    var contextAlcoholPreviousDay: Bool
    var contextIntenseTraining: Bool
    var contextEarlyCaffeine: Bool
    var contextPerceivedStress: Bool
    var contextIllness: Bool
    var contextPain: Bool
    var contextMedicationTaken: Bool

    var type: BPSessionType { BPSessionType(rawValue: typeRaw) ?? .adHoc }
    var source: HealthSource { HealthSource(rawValue: sourceRaw) ?? .cuff }

    init(id: UUID = UUID(), date: Date, type: BPSessionType,
         averageSystolic: Double, averageDiastolic: Double,
         averagePulse: Double? = nil, adherence: Double = 1,
         source: HealthSource = .cuff) {
        self.id = id
        self.date = date
        self.typeRaw = type.rawValue
        self.averageSystolic = averageSystolic
        self.averageDiastolic = averageDiastolic
        self.averagePulse = averagePulse
        self.adherence = adherence
        self.sourceRaw = source.rawValue
        self.createdAt = Date()
        self.contextSleepPoor = false
        self.contextAlcoholPreviousDay = false
        self.contextIntenseTraining = false
        self.contextEarlyCaffeine = false
        self.contextPerceivedStress = false
        self.contextIllness = false
        self.contextPain = false
        self.contextMedicationTaken = false
    }

    var contextLabels: [String] {
        var out: [String] = []
        if contextSleepPoor { out.append("Sono ruim") }
        if contextAlcoholPreviousDay { out.append("Álcool no dia anterior") }
        if contextIntenseTraining { out.append("Treino intenso") }
        if contextEarlyCaffeine { out.append("Cafeína precoce") }
        if contextPerceivedStress { out.append("Estresse percebido") }
        if contextIllness { out.append("Doença") }
        if contextPain { out.append("Dor") }
        if contextMedicationTaken { out.append("Medicação tomada") }
        return out
    }
}

/// Etapas do protocolo matinal. A contagem de aderência usa esta lista.
enum MorningProtocol {

    static let title = "Medição matinal de referência"

    static let guidance =
        "Faça três medições pela manhã, antes de comer, treinar ou usar cafeína, "
      + "nicotina e outros estimulantes. Sente-se confortavelmente, mantenha os "
      + "pés apoiados no chão, apoie o braço e permaneça em repouso por alguns "
      + "minutos. Use sempre o manguito de braço na posição recomendada pelo "
      + "fabricante."

    struct Step: Identifiable {
        let id: Int
        let text: String
        /// Segundos de espera antes de liberar a próxima etapa. Zero quando a
        /// etapa não tem tempo definido.
        let waitSeconds: Int
        /// A etapa registra uma leitura.
        let capturesReading: Bool
    }

    static let steps: [Step] = [
        .init(id: 1, text: "Acordar e ir ao banheiro, se necessário.",
              waitSeconds: 0, capturesReading: false),
        .init(id: 2, text: "Sentar-se e repousar por cinco minutos.",
              waitSeconds: 300, capturesReading: false),
        .init(id: 3, text: "Fazer a primeira medida.",
              waitSeconds: 0, capturesReading: true),
        .init(id: 4, text: "Aguardar um minuto.",
              waitSeconds: 60, capturesReading: false),
        .init(id: 5, text: "Fazer a segunda medida.",
              waitSeconds: 0, capturesReading: true),
        .init(id: 6, text: "Aguardar um minuto.",
              waitSeconds: 60, capturesReading: false),
        .init(id: 7, text: "Fazer a terceira medida.",
              waitSeconds: 0, capturesReading: true),
        .init(id: 8, text: "Salvar a média das três leituras como média matinal "
                         + "de referência.", waitSeconds: 0, capturesReading: false),
    ]

    static let nightGuidance =
        "Use para acompanhar como o dia se refletiu na sua pressão. Não substitui "
      + "a média matinal padronizada para análise de tendência."

    /// Aviso fixo exibido junto de qualquer resultado. O aplicativo descreve o
    /// registro; conduta é do profissional que acompanha a pessoa.
    static let conductNotice =
        "Leve estes registros ao profissional que acompanha você. Este aplicativo "
      + "não orienta ajuste de medicação, sal, eletrólitos ou dieta."
}
