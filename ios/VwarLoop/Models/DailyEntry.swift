import Foundation
import SwiftData

/// Origem de um valor. Aparece no painel de qualidade dos dados: saber de onde
/// o numero veio e parte de saber o quanto confiar nele.
enum DataSource: String, Codable, CaseIterable, Sendable {
    case manual
    case healthKit
    case bluetooth

    var label: String {
        switch self {
        case .manual: return "manual"
        case .healthKit: return "Saúde da Apple"
        case .bluetooth: return "Bluetooth (pulseira)"
        }
    }
}

/// Um dia de dados. Chave e o dia normalizado para meia-noite local.
///
/// Tudo e opcional de proposito: um dia parcial e o caso normal, nao a exceção.
/// O motor de scores renormaliza os pesos sobre o que existe, em vez de tratar
/// campo ausente como zero.
@Model
final class DailyEntry {
    /// Meia-noite local do dia. Unico por dia.
    @Attribute(.unique) var day: Date

    // Cardiovascular e sono
    var sleepHours: Double?
    var sleepQuality: Double?      // 1...5
    var restingHR: Double?         // bpm
    var hrv: Double?               // ms
    var spo2: Double?              // %
    var bodyTemperature: Double?   // °C

    // Corpo e atividade
    var weight: Double?            // kg
    var steps: Double?
    var activeEnergy: Double?      // kcal
    var workoutType: String?
    var workoutMinutes: Double?
    var workoutIntensity: Double?  // 1...5

    // Subjetivo — a parte que nenhum sensor mede e que mais explica o dia
    var mood: Double?              // 1...5
    var energy: Double?            // 1...5
    var stress: Double?            // 1...5, 5 = muito estressada
    var soreness: Double?          // 1...5, 5 = muito dolorida
    var focus: Double?             // 1...5

    var notes: String?
    var sourceRaw: String
    var updatedAt: Date

    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    init(day: Date, source: DataSource = .manual) {
        self.day = Calendar.current.startOfDay(for: day)
        self.sourceRaw = source.rawValue
        self.updatedAt = Date()
    }

    /// Aplica um valor vindo da Saude da Apple sem sobrescrever o que voce
    /// digitou. Entrada manual sempre vence a importacao automatica — voce sabe
    /// coisas que o sensor nao sabe.
    func fillIfEmpty(_ keyPath: ReferenceWritableKeyPath<DailyEntry, Double?>,
                     with value: Double?) {
        guard let value, self[keyPath: keyPath] == nil else { return }
        self[keyPath: keyPath] = value
        updatedAt = Date()
    }
}

// MARK: - Backup

/// Forma serializavel de um dia, para exportar e importar.
/// Compativel com o `/api/export` do servidor Python — os dois lados falam o
/// mesmo JSON, entao da para migrar do web app para o iOS e vice-versa.
struct EntryDTO: Codable {
    var day: String
    var sleep_hours: Double?
    var sleep_quality: Double?
    var resting_hr: Double?
    var hrv: Double?
    var spo2: Double?
    var temperature: Double?
    var weight: Double?
    var steps: Double?
    var mood: Double?
    var energy: Double?
    var stress: Double?
    var soreness: Double?
    var focus: Double?
    var workout_type: String?
    var workout_minutes: Double?
    var workout_intensity: Double?
    var notes: String?
    var source: String?

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    init(_ e: DailyEntry) {
        day = Self.dayFormatter.string(from: e.day)
        sleep_hours = e.sleepHours
        sleep_quality = e.sleepQuality
        resting_hr = e.restingHR
        hrv = e.hrv
        spo2 = e.spo2
        temperature = e.bodyTemperature
        weight = e.weight
        steps = e.steps
        mood = e.mood
        energy = e.energy
        stress = e.stress
        soreness = e.soreness
        focus = e.focus
        workout_type = e.workoutType
        workout_minutes = e.workoutMinutes
        workout_intensity = e.workoutIntensity
        notes = e.notes
        source = e.sourceRaw
    }

    /// Escreve num `DailyEntry` existente ou novo.
    func apply(to e: DailyEntry) {
        e.sleepHours = sleep_hours ?? e.sleepHours
        e.sleepQuality = sleep_quality ?? e.sleepQuality
        e.restingHR = resting_hr ?? e.restingHR
        e.hrv = hrv ?? e.hrv
        e.spo2 = spo2 ?? e.spo2
        e.bodyTemperature = temperature ?? e.bodyTemperature
        e.weight = weight ?? e.weight
        e.steps = steps ?? e.steps
        e.mood = mood ?? e.mood
        e.energy = energy ?? e.energy
        e.stress = stress ?? e.stress
        e.soreness = soreness ?? e.soreness
        e.focus = focus ?? e.focus
        e.workoutType = workout_type ?? e.workoutType
        e.workoutMinutes = workout_minutes ?? e.workoutMinutes
        e.workoutIntensity = workout_intensity ?? e.workoutIntensity
        e.notes = notes ?? e.notes
        e.updatedAt = Date()
    }

    var parsedDay: Date? { Self.dayFormatter.date(from: day) }
}

struct BackupFile: Codable {
    var exported_at: String
    var entries: [EntryDTO]
}
