import Foundation
import HealthKit

/// Ponte com a Saude da Apple.
///
/// Caminho diario:  VWAR Loop Life → G Band → Saúde da Apple → este app.
///
/// O G Band ja escreve na Saude. Em vez de decodificar o protocolo BLE
/// proprietario so para ter os dados de ontem, lemos o que ja esta la. O
/// Bluetooth direto (`BandManager`) continua util para leitura ao vivo e para
/// intervalos RR, que a Saude nao guarda.
///
/// Importante: NAO importamos glicose. O G Band escreve glicose na Saude, mas
/// esse valor e uma estimativa optica sem validacao. Ver `UnvalidatedMetrics`.
@MainActor
final class HealthKitBridge: ObservableObject {

    enum Status: Equatable {
        case unavailable
        case notRequested
        case authorized
        case failed(String)
        /// O app foi assinado sem o entitlement do HealthKit — o caso normal ao
        /// instalar por AltStore/SideStore com um Apple ID gratuito, que não
        /// recebe a capacidade do HealthKit. Merece mensagem própria: não é bug
        /// nem permissão negada, e o resto do app continua funcionando.
        case missingEntitlement
    }

    @Published private(set) var status: Status = .notRequested
    @Published private(set) var lastSync: Date?
    @Published private(set) var isSyncing = false

    private let store = HKHealthStore()

    /// Um dia importado da Saude, antes de virar `DailyEntry`.
    struct DaySample {
        var day: Date
        var restingHR: Double?
        var hrv: Double?
        var spo2: Double?
        var sleepHours: Double?
        var steps: Double?
        var activeEnergy: Double?
        var bodyTemperature: Double?
        var weight: Double?
    }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.oxygenSaturation),
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.bodyTemperature),
            HKQuantityType(.bodyMass),
            HKQuantityType(.heartRate),
        ]
        types.insert(HKCategoryType(.sleepAnalysis))
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
        } catch {
            // Sem o entitlement, o iOS recusa com "missing entitlement" em vez
            // de simplesmente negar. Distinguir os dois evita que você fique
            // procurando uma permissão que não existe para conceder.
            let message = error.localizedDescription.lowercased()
            let nsError = error as NSError
            if message.contains("entitlement")
                || message.contains("authorization request")
                || nsError.code == HKError.errorAuthorizationDenied.rawValue
                && message.contains("healthkit") {
                status = .missingEntitlement
            } else {
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// Le os ultimos `days` dias e devolve um resumo por dia.
    ///
    /// O iOS nao informa se o usuario negou leitura — `authorizationStatus` so
    /// vale para escrita. Entao um retorno vazio pode significar "sem permissao"
    /// ou "sem dados", e a interface precisa dizer isso em vez de fingir certeza.
    func fetchRecentDays(_ days: Int = 60) async -> [DaySample] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        isSyncing = true
        defer { isSyncing = false; lastSync = Date() }

        let cal = Calendar.current
        let end = cal.startOfDay(for: Date()).addingTimeInterval(86_400)
        guard let start = cal.date(byAdding: .day, value: -days, to: end) else { return [] }

        var byDay: [Date: DaySample] = [:]
        func slot(_ day: Date) -> DaySample {
            byDay[day] ?? DaySample(day: day)
        }

        // Medias diarias
        let averaged: [(HKQuantityType, HKUnit, WritableKeyPath<DaySample, Double?>)] = [
            (HKQuantityType(.restingHeartRate), .count().unitDivided(by: .minute()), \.restingHR),
            (HKQuantityType(.heartRateVariabilitySDNN), .secondUnit(with: .milli), \.hrv),
            (HKQuantityType(.oxygenSaturation), .percent(), \.spo2),
            (HKQuantityType(.bodyTemperature), .degreeCelsius(), \.bodyTemperature),
            (HKQuantityType(.bodyMass), .gramUnit(with: .kilo), \.weight),
        ]
        for (type, unit, keyPath) in averaged {
            let daily = await statistics(type, unit: unit, options: .discreteAverage,
                                         start: start, end: end)
            for (day, value) in daily {
                var s = slot(day)
                // SpO2 vem como fracao (0...1); a interface mostra porcentagem.
                s[keyPath: keyPath] = (type == HKQuantityType(.oxygenSaturation))
                    ? value * 100 : value
                byDay[day] = s
            }
        }

        // Somas diarias
        let summed: [(HKQuantityType, HKUnit, WritableKeyPath<DaySample, Double?>)] = [
            (HKQuantityType(.stepCount), .count(), \.steps),
            (HKQuantityType(.activeEnergyBurned), .kilocalorie(), \.activeEnergy),
        ]
        for (type, unit, keyPath) in summed {
            let daily = await statistics(type, unit: unit, options: .cumulativeSum,
                                         start: start, end: end)
            for (day, value) in daily {
                var s = slot(day)
                s[keyPath: keyPath] = value
                byDay[day] = s
            }
        }

        // Sono precisa de tratamento proprio: sao intervalos categoricos, e a
        // noite atravessa a meia-noite. Atribuimos a noite ao dia em que se
        // ACORDA, que e como todo app de sono reporta.
        for (day, hours) in await sleepHoursByWakeDay(start: start, end: end) {
            var s = slot(day)
            s.sleepHours = hours
            byDay[day] = s
        }

        return byDay.values.sorted { $0.day > $1.day }
    }

    // MARK: - Consultas

    private func statistics(_ type: HKQuantityType, unit: HKUnit,
                            options: HKStatisticsOptions,
                            start: Date, end: Date) async -> [Date: Double] {
        await withCheckedContinuation { continuation in
            let anchor = Calendar.current.startOfDay(for: start)
            let interval = DateComponents(day: 1)
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

            let query = HKStatisticsCollectionQuery(
                quantityType: type, quantitySamplePredicate: predicate,
                options: options, anchorDate: anchor, intervalComponents: interval)

            query.initialResultsHandler = { _, results, _ in
                guard let results else {
                    continuation.resume(returning: [:])
                    return
                }
                var out: [Date: Double] = [:]
                results.enumerateStatistics(from: start, to: end) { stat, _ in
                    let quantity = options.contains(.cumulativeSum)
                        ? stat.sumQuantity() : stat.averageQuantity()
                    if let quantity {
                        let day = Calendar.current.startOfDay(for: stat.startDate)
                        out[day] = quantity.doubleValue(for: unit)
                    }
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }

    /// Horas de sono efetivo por dia de despertar.
    ///
    /// Conta apenas os estagios de sono real (`asleep*`) e ignora `inBed` e
    /// `awake` — tempo na cama nao e sono, e tratar como se fosse infla a metrica
    /// justamente nas noites ruins, quando ela mais importa.
    private func sleepHoursByWakeDay(start: Date, end: Date) async -> [Date: Double] {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let query = HKSampleQuery(
                sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, _ in
                guard let samples = samples as? [HKCategorySample] else {
                    continuation.resume(returning: [:])
                    return
                }
                let asleep: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                ]
                var seconds: [Date: Double] = [:]
                for sample in samples where asleep.contains(sample.value) {
                    let wakeDay = Calendar.current.startOfDay(for: sample.endDate)
                    seconds[wakeDay, default: 0] +=
                        sample.endDate.timeIntervalSince(sample.startDate)
                }
                continuation.resume(
                    returning: seconds.mapValues { ($0 / 3600 * 10).rounded() / 10 })
            }
            store.execute(query)
        }
    }
}
