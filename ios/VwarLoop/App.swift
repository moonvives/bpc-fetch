import SwiftData
import SwiftUI

@main
struct VwarLoopApp: App {
    private let container: ModelContainer = {
        let schema = Schema([
            UserProfile.self, MetricObservation.self, SleepSession.self,
            WorkoutSession.self, BloodPressureReading.self, BloodPressureSession.self,
            LabResult.self, DailyContextLog.self, MedicationContextLog.self,
            SymptomLog.self,
        ])
        do {
            return try ModelContainer(for: schema)
        } catch {
            let memory = ModelConfiguration(isStoredInMemoryOnly: true)
            // swiftlint:disable:next force_try
            return try! ModelContainer(for: schema, configurations: memory)
        }
    }()

    @StateObject private var health = AppleHealthSource()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(health)
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Hoje", systemImage: "square.text.square") }
            RecoveryView()
                .tabItem { Label("Recuperação", systemImage: "moon.zzz") }
            TrainingView()
                .tabItem { Label("Treino", systemImage: "figure.run") }
            HealthHubView()
                .tabItem { Label("Saúde", systemImage: "heart.text.square") }
            JournalView()
                .tabItem { Label("Diário", systemImage: "square.and.pencil") }
        }
        .tint(Palette.neutral(scheme))
    }
}

// MARK: - Consultas compartilhadas

/// Funções de leitura usadas pelas telas. Ficam fora das views para que a mesma
/// série alimente gráfico, tabela e texto sem divergir.
enum Query {

    static func dailyValues(_ observations: [MetricObservation],
                            kind: MetricKind) -> [(day: Date, value: Double)] {
        let filtered = observations.filter { $0.kind == kind }
        var byDay: [Date: [Double]] = [:]
        for obs in filtered { byDay[obs.day, default: []].append(obs.value) }
        return byDay
            .compactMap { day, values in
                Baseline.mean(values).map { (day: day, value: $0) }
            }
            .sorted { $0.day > $1.day }
    }

    static func sourceName(_ observations: [MetricObservation],
                           kind: MetricKind) -> String {
        observations.first { $0.kind == kind && !$0.sourceName.isEmpty }?
            .sourceName ?? ""
    }

    static func sleepMinutes(_ sessions: [SleepSession]) -> [(day: Date, value: Double)] {
        sessions.map { (day: $0.wakeDay, value: $0.asleepMinutes) }
            .sorted { $0.day > $1.day }
    }

    /// Carga semanal a partir das sessões, agrupada por semana ISO.
    static func weeklyLoad(_ workouts: [WorkoutSession],
                           maxHeartRate: Double?) -> [(weekStart: Date, load: Double,
                                                       sessions: Int)] {
        let calendar = Calendar(identifier: .iso8601)
        var byWeek: [Date: (Double, Int)] = [:]
        for workout in workouts {
            guard let interval = calendar.dateInterval(of: .weekOfYear,
                                                       for: workout.start) else { continue }
            let current = byWeek[interval.start] ?? (0, 0)
            byWeek[interval.start] = (current.0 + workout.load(maxHeartRate: maxHeartRate).value,
                                      current.1 + 1)
        }
        return byWeek
            .map { (weekStart: $0.key, load: $0.value.0, sessions: $0.value.1) }
            .sorted { $0.weekStart > $1.weekStart }
    }

    static func contextTags(_ logs: [DailyContextLog], on day: Date) -> [ContextTag] {
        let normalized = Calendar.current.startOfDay(for: day)
        return logs.first { $0.day == normalized }?.tags ?? []
    }

    /// Sessões matinais padronizadas, do mais recente ao mais antigo.
    static func morningSessions(_ sessions: [BloodPressureSession])
        -> [BloodPressureSession] {
        sessions.filter { $0.type == .morningReference }.sorted { $0.date > $1.date }
    }
}

/// Saudação curta por período do dia. Sem exclamação e sem frase motivacional.
enum Greeting {
    static var current: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Bom dia"
        case 12..<18: return "Boa tarde"
        default: return "Boa noite"
        }
    }
}
