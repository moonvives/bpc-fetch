import Foundation
import SwiftData

// MARK: - Fontes

/// Origem de um dado. Aparece em todo gráfico e em toda tabela.
enum HealthSource: String, Codable, CaseIterable, Sendable {
    case appleHealth
    case strava
    case cuff          // aparelho de braço, importado via Saúde
    case manual

    var label: String {
        switch self {
        case .appleHealth: return "Saúde da Apple"
        case .strava: return "Strava"
        case .cuff: return "Manguito OMRON"
        case .manual: return "Registro manual"
        }
    }

    /// Medida direta pelo aparelho, em oposição a valor derivado ou estimado.
    var isDirectMeasurement: Bool {
        switch self {
        case .cuff, .manual: return true
        case .appleHealth, .strava: return false
        }
    }
}

// MARK: - Perfil

@Model
final class UserProfile {
    var displayName: String
    var birthYear: Int?
    var sleepTargetHours: Double
    var trackMenstrualContext: Bool
    var bloodPressureReminderPerWeek: Int
    var createdAt: Date

    init(displayName: String = "",
         sleepTargetHours: Double = 8,
         trackMenstrualContext: Bool = false,
         bloodPressureReminderPerWeek: Int = 2) {
        self.displayName = displayName
        self.sleepTargetHours = sleepTargetHours
        self.trackMenstrualContext = trackMenstrualContext
        self.bloodPressureReminderPerWeek = bloodPressureReminderPerWeek
        self.createdAt = Date()
    }
}

// MARK: - Observação genérica

/// Métricas contínuas importadas. Cada observação carrega sua fonte e se é
/// medida direta ou derivada, porque isso muda o quanto ela sustenta.
enum MetricKind: String, Codable, CaseIterable, Sendable {
    case heartRate
    case restingHeartRate
    case sleepingHeartRate
    case heartRateVariability
    case respiratoryRate
    case wristTemperature
    case oxygenSaturation
    case steps
    case activeEnergy
    case vo2Max
    case bodyMass
    case bodyFatPercentage
    case caffeine
    case alcohol

    var label: String {
        switch self {
        case .heartRate: return "Frequência cardíaca"
        case .restingHeartRate: return "FC de repouso"
        case .sleepingHeartRate: return "FC durante o sono"
        case .heartRateVariability: return "Variabilidade da FC"
        case .respiratoryRate: return "Frequência respiratória"
        case .wristTemperature: return "Temperatura cutânea"
        case .oxygenSaturation: return "Saturação de oxigênio"
        case .steps: return "Passos"
        case .activeEnergy: return "Gasto ativo"
        case .vo2Max: return "VO₂ máximo"
        case .bodyMass: return "Peso"
        case .bodyFatPercentage: return "Percentual de gordura"
        case .caffeine: return "Cafeína"
        case .alcohol: return "Álcool"
        }
    }

    var unit: String {
        switch self {
        case .heartRate, .restingHeartRate, .sleepingHeartRate: return "bpm"
        case .heartRateVariability: return "ms"
        case .respiratoryRate: return "irpm"
        case .wristTemperature: return "°C"
        case .oxygenSaturation: return "%"
        case .steps: return "passos"
        case .activeEnergy: return "kcal"
        case .vo2Max: return "mL/kg/min"
        case .bodyMass: return "kg"
        case .bodyFatPercentage: return "%"
        case .caffeine: return "mg"
        case .alcohol: return "doses"
        }
    }

    var decimals: Int {
        switch self {
        case .heartRateVariability, .steps, .activeEnergy, .caffeine: return 0
        case .wristTemperature: return 1
        default: return 1
        }
    }

    /// Métricas cuja leitura só descreve tendência individual e nunca condição
    /// clínica isolada.
    var trendOnly: Bool {
        self == .wristTemperature || self == .vo2Max
    }
}

@Model
final class MetricObservation {
    var kindRaw: String
    var value: Double
    var start: Date
    var end: Date
    var sourceRaw: String
    var sourceName: String   // nome do app/aparelho reportado pela Saúde
    var isDerived: Bool

    var kind: MetricKind { MetricKind(rawValue: kindRaw) ?? .heartRate }
    var source: HealthSource { HealthSource(rawValue: sourceRaw) ?? .appleHealth }
    var day: Date { Calendar.current.startOfDay(for: start) }

    init(kind: MetricKind, value: Double, start: Date, end: Date,
         source: HealthSource, sourceName: String = "", isDerived: Bool = false) {
        self.kindRaw = kind.rawValue
        self.value = value
        self.start = start
        self.end = end
        self.sourceRaw = source.rawValue
        self.sourceName = sourceName
        self.isDerived = isDerived
    }
}

// MARK: - Sono

@Model
final class SleepSession {
    /// Dia do despertar. Uma noite pertence ao dia em que termina.
    var wakeDay: Date
    var bedTime: Date
    var wakeTime: Date
    var asleepMinutes: Double
    var inBedMinutes: Double
    var awakenings: Int
    var deepMinutes: Double?
    var remMinutes: Double?
    var coreMinutes: Double?
    var sourceRaw: String
    var sourceName: String

    var source: HealthSource { HealthSource(rawValue: sourceRaw) ?? .appleHealth }

    /// Eficiência: sono efetivo sobre tempo na cama. Só existe quando as duas
    /// medidas estão presentes.
    var efficiency: Double? {
        guard inBedMinutes > 0, asleepMinutes > 0 else { return nil }
        return min(100, asleepMinutes / inBedMinutes * 100)
    }

    var hasStages: Bool { deepMinutes != nil || remMinutes != nil || coreMinutes != nil }

    init(wakeDay: Date, bedTime: Date, wakeTime: Date, asleepMinutes: Double,
         inBedMinutes: Double, awakenings: Int = 0, source: HealthSource = .appleHealth,
         sourceName: String = "") {
        self.wakeDay = Calendar.current.startOfDay(for: wakeDay)
        self.bedTime = bedTime
        self.wakeTime = wakeTime
        self.asleepMinutes = asleepMinutes
        self.inBedMinutes = inBedMinutes
        self.awakenings = awakenings
        self.sourceRaw = source.rawValue
        self.sourceName = sourceName
    }
}

// MARK: - Treino

enum IntensityZone: String, Codable, CaseIterable, Sendable {
    case light, moderate, vigorous, high

    var label: String {
        switch self {
        case .light: return "Leve"
        case .moderate: return "Moderada"
        case .vigorous: return "Vigorosa"
        case .high: return "Alta"
        }
    }
}

@Model
final class WorkoutSession {
    var start: Date
    var durationMinutes: Double
    var activityType: String
    var distanceMeters: Double?
    var elevationGainMeters: Double?
    var averageHeartRate: Double?
    var maxHeartRate: Double?
    var averagePaceSecondsPerKm: Double?
    var averagePowerWatts: Double?
    var perceivedExertion: Int?      // 1...10, informado pela pessoa
    var isStrengthTraining: Bool
    var muscleGroups: String?
    var sourceRaw: String
    var sourceName: String
    var externalID: String?          // identificador na origem, evita duplicata

    var source: HealthSource { HealthSource(rawValue: sourceRaw) ?? .appleHealth }
    var day: Date { Calendar.current.startOfDay(for: start) }

    init(start: Date, durationMinutes: Double, activityType: String,
         source: HealthSource, sourceName: String = "",
         isStrengthTraining: Bool = false, externalID: String? = nil) {
        self.start = start
        self.durationMinutes = durationMinutes
        self.activityType = activityType
        self.sourceRaw = source.rawValue
        self.sourceName = sourceName
        self.isStrengthTraining = isStrengthTraining
        self.externalID = externalID
    }

    /// Carga da sessão: duração × esforço. Usa esforço percebido quando existe,
    /// senão deriva de FC média. Sem nenhum dos dois, a sessão conta pela duração
    /// e a carga fica marcada como estimativa fraca.
    func load(maxHeartRate hrMax: Double?) -> (value: Double, basis: String) {
        if let rpe = perceivedExertion {
            return (durationMinutes * Double(rpe), "esforço percebido")
        }
        if let avg = averageHeartRate, let hrMax, hrMax > 60 {
            let fraction = max(0.3, min(1.0, avg / hrMax))
            return (durationMinutes * fraction * 10, "frequência cardíaca média")
        }
        return (durationMinutes * 4, "somente duração")
    }
}
