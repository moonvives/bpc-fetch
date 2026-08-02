import Foundation
import HealthKit

/// Importação a partir da Saúde da Apple.
///
/// É também o caminho da pressão arterial: o aplicativo do aparelho grava as
/// leituras do manguito na Saúde, e a origem chega junto do dado. Leituras cuja
/// origem é um aparelho de braço são marcadas como medida de manguito; qualquer
/// outra origem entra como registro manual e fica fora da tendência padronizada.
@MainActor
final class AppleHealthSource: ObservableObject {

    enum Status: Equatable {
        case notRequested
        case unavailable
        case authorized
        case entitlementMissing
        case failed(String)
    }

    struct ImportSummary {
        var metrics = 0
        var sleepSessions = 0
        var workouts = 0
        var pressureReadings = 0
        var startedAt = Date()
        var finishedAt: Date?
    }

    @Published private(set) var status: Status = .notRequested
    @Published private(set) var isImporting = false
    @Published private(set) var lastSummary: ImportSummary?
    /// Trilha de auditoria das importações.
    @Published private(set) var auditTrail: [String] = []

    private let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.respiratoryRate),
            HKQuantityType(.oxygenSaturation),
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.vo2Max),
            HKQuantityType(.bodyMass),
            HKQuantityType(.bodyFatPercentage),
            HKQuantityType(.dietaryCaffeine),
            HKQuantityType(.numberOfAlcoholicBeverages),
            HKQuantityType(.bloodPressureSystolic),
            HKQuantityType(.bloodPressureDiastolic),
        ]
        if #available(iOS 16.0, *) {
            types.insert(HKQuantityType(.appleSleepingWristTemperature))
        }
        types.insert(HKCategoryType(.sleepAnalysis))
        types.insert(HKObjectType.workoutType())
        return types
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = .unavailable
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            status = .authorized
            note("Permissões de leitura solicitadas.")
        } catch {
            let text = error.localizedDescription.lowercased()
            status = text.contains("entitlement")
                ? .entitlementMissing
                : .failed(error.localizedDescription)
        }
    }

    private func note(_ text: String) {
        auditTrail.insert("\(Format.dayAndTime.string(from: Date())) — \(text)",
                          at: 0)
        if auditTrail.count > 60 { auditTrail.removeLast() }
    }

    // MARK: - Leituras de pressão

    struct PressureSample {
        var timestamp: Date
        var systolic: Int
        var diastolic: Int
        var sourceName: String
        var isCuff: Bool
    }

    /// Nomes de origem que indicam aparelho de braço. Só estes formam a série de
    /// tendência; o restante fica registrado como entrada manual.
    private nonisolated static let cuffSourceHints = ["omron", "connect", "hem-"]

    func fetchPressure(days: Int = 180) async -> [PressureSample] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let calendar = Calendar.current
        let end = Date()
        guard let start = calendar.date(byAdding: .day, value: -days, to: end) else {
            return []
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        // A pressão vem como correlação de duas amostras. Buscar o tipo de
        // correlação mantém sistólica e diastólica pareadas na mesma leitura.
        let correlationType = HKCorrelationType(.bloodPressure)

        let samples: [PressureSample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: correlationType,
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [
                                        NSSortDescriptor(
                                            key: HKSampleSortIdentifierStartDate,
                                            ascending: false)
                                      ]) { _, results, _ in
                guard let correlations = results as? [HKCorrelation] else {
                    continuation.resume(returning: [])
                    return
                }
                var out: [PressureSample] = []
                let unit = HKUnit.millimeterOfMercury()
                for correlation in correlations {
                    let systolicType = HKQuantityType(.bloodPressureSystolic)
                    let diastolicType = HKQuantityType(.bloodPressureDiastolic)
                    guard
                        let s = correlation.objects(for: systolicType).first
                            as? HKQuantitySample,
                        let d = correlation.objects(for: diastolicType).first
                            as? HKQuantitySample
                    else { continue }

                    let name = correlation.sourceRevision.source.name
                    let lower = name.lowercased()
                    let isCuff = Self.cuffSourceHints.contains { lower.contains($0) }

                    out.append(PressureSample(
                        timestamp: correlation.startDate,
                        systolic: Int(s.quantity.doubleValue(for: unit).rounded()),
                        diastolic: Int(d.quantity.doubleValue(for: unit).rounded()),
                        sourceName: name,
                        isCuff: isCuff))
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }

        note("Pressão arterial: \(samples.count) leituras lidas da Saúde.")
        return samples
    }

    // MARK: - Séries diárias

    /// Estatística diária de uma métrica quantitativa.
    func dailySeries(_ kind: MetricKind, days: Int = 120)
        async -> [(day: Date, value: Double, sourceName: String)] {

        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        guard let (type, unit, options) = Self.mapping(for: kind) else { return [] }

        let calendar = Calendar.current
        let end = calendar.startOfDay(for: Date()).addingTimeInterval(86_400)
        guard let start = calendar.date(byAdding: .day, value: -days, to: end) else {
            return []
        }

        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let query = HKStatisticsCollectionQuery(
                quantityType: type, quantitySamplePredicate: predicate,
                options: options, anchorDate: calendar.startOfDay(for: start),
                intervalComponents: DateComponents(day: 1))

            query.initialResultsHandler = { _, results, _ in
                guard let results else {
                    continuation.resume(returning: [])
                    return
                }
                var out: [(Date, Double, String)] = []
                results.enumerateStatistics(from: start, to: end) { stat, _ in
                    let quantity = options.contains(.cumulativeSum)
                        ? stat.sumQuantity() : stat.averageQuantity()
                    guard let quantity else { return }
                    var value = quantity.doubleValue(for: unit)
                    if kind == .oxygenSaturation || kind == .bodyFatPercentage {
                        value *= 100   // a Saúde guarda fração
                    }
                    let name = stat.sources?.first?.name ?? ""
                    out.append((calendar.startOfDay(for: stat.startDate), value, name))
                }
                continuation.resume(
                    returning: out.sorted { $0.0 > $1.0 }
                        .map { (day: $0.0, value: $0.1, sourceName: $0.2) })
            }
            store.execute(query)
        }
    }

    private static func mapping(for kind: MetricKind)
        -> (HKQuantityType, HKUnit, HKStatisticsOptions)? {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        switch kind {
        case .heartRate:
            return (HKQuantityType(.heartRate), bpm, .discreteAverage)
        case .restingHeartRate:
            return (HKQuantityType(.restingHeartRate), bpm, .discreteAverage)
        case .sleepingHeartRate:
            return (HKQuantityType(.heartRate), bpm, .discreteAverage)
        case .heartRateVariability:
            return (HKQuantityType(.heartRateVariabilitySDNN),
                    .secondUnit(with: .milli), .discreteAverage)
        case .respiratoryRate:
            return (HKQuantityType(.respiratoryRate), bpm, .discreteAverage)
        case .oxygenSaturation:
            return (HKQuantityType(.oxygenSaturation), .percent(), .discreteAverage)
        case .steps:
            return (HKQuantityType(.stepCount), .count(), .cumulativeSum)
        case .activeEnergy:
            return (HKQuantityType(.activeEnergyBurned), .kilocalorie(), .cumulativeSum)
        case .vo2Max:
            let unit = HKUnit.literUnit(with: .milli)
                .unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute()))
            return (HKQuantityType(.vo2Max), unit, .discreteAverage)
        case .bodyMass:
            return (HKQuantityType(.bodyMass), .gramUnit(with: .kilo), .discreteAverage)
        case .bodyFatPercentage:
            return (HKQuantityType(.bodyFatPercentage), .percent(), .discreteAverage)
        case .caffeine:
            return (HKQuantityType(.dietaryCaffeine), .gramUnit(with: .milli),
                    .cumulativeSum)
        case .alcohol:
            return (HKQuantityType(.numberOfAlcoholicBeverages), .count(),
                    .cumulativeSum)
        case .wristTemperature:
            if #available(iOS 16.0, *) {
                return (HKQuantityType(.appleSleepingWristTemperature),
                        .degreeCelsius(), .discreteAverage)
            }
            return nil
        }
    }

    // MARK: - Sono

    struct SleepNight {
        var wakeDay: Date
        var bedTime: Date
        var wakeTime: Date
        var asleepMinutes: Double
        var inBedMinutes: Double
        var awakenings: Int
        var deepMinutes: Double
        var remMinutes: Double
        var coreMinutes: Double
        var sourceName: String
    }

    /// Agrupa as amostras de sono por dia de despertar.
    ///
    /// Conta somente estágios de sono efetivo. Tempo na cama entra separado, para
    /// a eficiência; tratar tempo na cama como sono infla a métrica justamente
    /// nas noites ruins.
    func fetchSleep(days: Int = 120) async -> [SleepNight] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let calendar = Calendar.current
        let end = Date()
        guard let start = calendar.date(byAdding: .day, value: -days, to: end) else {
            return []
        }

        let nights: [SleepNight] = await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let query = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis),
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, results, _ in
                guard let samples = results as? [HKCategorySample] else {
                    continuation.resume(returning: [])
                    return
                }

                let asleepValues: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                ]

                var byDay: [Date: SleepNight] = [:]
                for sample in samples {
                    let wakeDay = calendar.startOfDay(for: sample.endDate)
                    let minutes = sample.endDate
                        .timeIntervalSince(sample.startDate) / 60
                    var night = byDay[wakeDay] ?? SleepNight(
                        wakeDay: wakeDay, bedTime: sample.startDate,
                        wakeTime: sample.endDate, asleepMinutes: 0,
                        inBedMinutes: 0, awakenings: 0, deepMinutes: 0,
                        remMinutes: 0, coreMinutes: 0,
                        sourceName: sample.sourceRevision.source.name)

                    night.bedTime = min(night.bedTime, sample.startDate)
                    night.wakeTime = max(night.wakeTime, sample.endDate)

                    if asleepValues.contains(sample.value) {
                        night.asleepMinutes += minutes
                        night.inBedMinutes += minutes
                        switch sample.value {
                        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                            night.deepMinutes += minutes
                        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                            night.remMinutes += minutes
                        case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                            night.coreMinutes += minutes
                        default: break
                        }
                    } else if sample.value
                                == HKCategoryValueSleepAnalysis.inBed.rawValue {
                        night.inBedMinutes += minutes
                    } else if sample.value
                                == HKCategoryValueSleepAnalysis.awake.rawValue {
                        night.awakenings += 1
                    }
                    byDay[wakeDay] = night
                }
                continuation.resume(
                    returning: byDay.values.sorted { $0.wakeDay > $1.wakeDay })
            }
            store.execute(query)
        }

        note("Sono: \(nights.count) noites lidas da Saúde.")
        return nights
    }

    // MARK: - Exercícios

    struct WorkoutRecord {
        var start: Date
        var minutes: Double
        var activity: String
        var distanceMeters: Double?
        var averageHeartRate: Double?
        var isStrength: Bool
        var sourceName: String
        var externalID: String
    }

    func fetchWorkouts(days: Int = 120) async -> [WorkoutRecord] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let calendar = Calendar.current
        let end = Date()
        guard let start = calendar.date(byAdding: .day, value: -days, to: end) else {
            return []
        }

        let records: [WorkoutRecord] = await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(),
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, results, _ in
                guard let workouts = results as? [HKWorkout] else {
                    continuation.resume(returning: [])
                    return
                }
                let out = workouts.map { w -> WorkoutRecord in
                    let distance = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?
                        .sumQuantity()?.doubleValue(for: .meter())
                    let hr = w.statistics(for: HKQuantityType(.heartRate))?
                        .averageQuantity()?
                        .doubleValue(for: .count().unitDivided(by: .minute()))
                    let strength = w.workoutActivityType == .traditionalStrengthTraining
                        || w.workoutActivityType == .functionalStrengthTraining
                    return WorkoutRecord(
                        start: w.startDate, minutes: w.duration / 60,
                        activity: Self.activityName(w.workoutActivityType),
                        distanceMeters: distance, averageHeartRate: hr,
                        isStrength: strength,
                        sourceName: w.sourceRevision.source.name,
                        externalID: w.uuid.uuidString)
                }
                continuation.resume(returning: out.sorted { $0.start > $1.start })
            }
            store.execute(query)
        }

        note("Exercícios: \(records.count) sessões lidas da Saúde.")
        return records
    }

    private nonisolated static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Corrida"
        case .walking: return "Caminhada"
        case .cycling: return "Ciclismo"
        case .swimming: return "Natação"
        case .traditionalStrengthTraining: return "Musculação"
        case .functionalStrengthTraining: return "Força funcional"
        case .highIntensityIntervalTraining: return "Intervalado"
        case .yoga: return "Ioga"
        case .pilates: return "Pilates"
        case .elliptical: return "Elíptico"
        case .rowing: return "Remo"
        case .dance: return "Dança"
        case .hiking: return "Trilha"
        case .stairClimbing: return "Escada"
        default: return "Exercício"
        }
    }
}
