import SwiftData
import SwiftUI

struct BloodPressureView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var health: AppleHealthSource

    @Query(sort: \BloodPressureSession.date, order: .reverse)
    private var sessions: [BloodPressureSession]
    @Query(sort: \BloodPressureReading.timestamp, order: .reverse)
    private var readings: [BloodPressureReading]

    @State private var period: TrendPeriod = .d30
    @State private var showingMorning = false
    @State private var showingNight = false
    @State private var importMessage: String?

    private var morning: [BloodPressureSession] { Query.morningSessions(sessions) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                latestPanel
                protocolActions
                trendPanel
                averagesPanel
                distributionPanel
                readingsTable
                Text(MorningProtocol.conductNotice)
                    .font(.caption)
                    .foregroundStyle(Palette.inkMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background(scheme))
        .navigationTitle("Pressão arterial")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingMorning) {
            MorningProtocolView(sessionType: .morningReference)
        }
        .sheet(isPresented: $showingNight) {
            MorningProtocolView(sessionType: .nightContext)
        }
        .task { await importFromHealth() }
    }

    // MARK: - Última medida

    private var latestPanel: some View {
        Panel {
            Text("Última medição válida")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.inkSecondary(scheme))

            if let last = readings.first(where: { $0.validity == .valid }) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(last.systolic)/\(last.diastolic)")
                        .font(.system(size: 46, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink(scheme))
                    Text("mmHg")
                        .font(.title3)
                        .foregroundStyle(Palette.inkMuted(scheme))
                }
                if let pulse = last.pulse {
                    Text("Pulso \(pulse) bpm")
                        .font(.subheadline)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                }
                HStack(spacing: 8) {
                    MetaTag(text: Format.dayAndTime.string(from: last.timestamp))
                    MetaTag(text: last.source.label)
                    if last.arm != .unspecified { MetaTag(text: last.arm.label) }
                }
            } else {
                Text("Ainda não há leitura registrada.")
                    .font(.body)
                    .foregroundStyle(Palette.inkMuted(scheme))
            }

            if let importMessage {
                Text(importMessage)
                    .font(.caption)
                    .foregroundStyle(Palette.inkMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Ações do protocolo

    private var protocolActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Panel {
                Text(MorningProtocol.title)
                    .font(.headline)
                    .foregroundStyle(Palette.ink(scheme))
                Text(MorningProtocol.guidance)
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showingMorning = true
                } label: {
                    Text("Iniciar sessão de três medidas")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .background(Palette.neutral(scheme),
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
            }

            Panel {
                Text(BPSessionType.nightContext.label)
                    .font(.headline)
                    .foregroundStyle(Palette.ink(scheme))
                Text(MorningProtocol.nightGuidance)
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Registrar leitura noturna") { showingNight = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.neutral(scheme))
            }
        }
    }

    // MARK: - Tendência

    private var systolicSeries: [(day: Date, value: Double)] {
        morning.map { (day: Calendar.current.startOfDay(for: $0.date),
                       value: $0.averageSystolic) }
    }

    private var diastolicSeries: [(day: Date, value: Double)] {
        morning.map { (day: Calendar.current.startOfDay(for: $0.date),
                       value: $0.averageDiastolic) }
    }

    private func windowed(_ series: [(day: Date, value: Double)])
        -> [(day: Date, value: Double)] {
        let cutoff = Date().addingTimeInterval(-Double(period.days) * 86_400)
        return series.filter { $0.day >= cutoff }
    }

    private var trendPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Tendência",
                           subtitle: "Somente sessões matinais padronizadas. "
                                   + "Origem: \(HealthSource.cuff.label).")

            Picker("Período", selection: $period) {
                ForEach([TrendPeriod.d7, .d30, .d90]) { p in
                    Text(p.shortLabel).tag(p)
                }
            }
            .pickerStyle(.segmented)

            Panel {
                SeriesChart(series: [
                    .init(id: "sys", name: "Sistólica", unit: "mmHg", decimals: 0,
                          points: windowed(systolicSeries),
                          color: { Palette.neutral($0) }),
                    .init(id: "dia", name: "Diastólica", unit: "mmHg", decimals: 0,
                          points: windowed(diastolicSeries),
                          color: { Palette.secondarySeries($0) }),
                ])
            }

            let adherence = adherencePercent
            Panel {
                Text("Protocolo completo")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.inkSecondary(scheme))
                Text(adherence == nil ? "Sem sessões no período"
                                      : Format.percent(adherence ?? 0))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink(scheme))
                Text("Percentual das sessões do período em que as três medidas "
                   + "foram concluídas.")
                    .font(.caption)
                    .foregroundStyle(Palette.inkMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var adherencePercent: Double? {
        let cutoff = Date().addingTimeInterval(-Double(period.days) * 86_400)
        let inWindow = morning.filter { $0.date >= cutoff }
        guard !inWindow.isEmpty else { return nil }
        let full = inWindow.filter { $0.adherence >= 0.999 }.count
        return Double(full) / Double(inWindow.count) * 100
    }

    // MARK: - Médias

    private var averagesPanel: some View {
        let cutoff = Date().addingTimeInterval(-Double(period.days) * 86_400)
        let morningWindow = morning.filter { $0.date >= cutoff }
        let nightWindow = sessions.filter {
            $0.type == .nightContext && $0.date >= cutoff
        }

        return VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Médias do período")
            Panel {
                averageRow("Média matinal", sessions: morningWindow)
                Divider().overlay(Palette.hairline(scheme))
                averageRow("Média noturna", sessions: nightWindow)
                Text("A média matinal padronizada é a base da tendência. A leitura "
                   + "noturna acompanha o dia e não a substitui.")
                    .font(.caption)
                    .foregroundStyle(Palette.inkMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func averageRow(_ title: String,
                            sessions: [BloodPressureSession]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.inkSecondary(scheme))
            if sessions.isEmpty {
                Text("Sem sessões no período.")
                    .font(.body)
                    .foregroundStyle(Palette.inkMuted(scheme))
            } else if let sys = Baseline.mean(sessions.map(\.averageSystolic)),
                      let dia = Baseline.mean(sessions.map(\.averageDiastolic)) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Format.decimal(sys, 0))/\(Format.decimal(dia, 0))")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink(scheme))
                    Text("mmHg")
                        .font(.subheadline)
                        .foregroundStyle(Palette.inkMuted(scheme))
                }
                Text("\(sessions.count) "
                   + (sessions.count == 1 ? "sessão" : "sessões"))
                    .font(.caption)
                    .foregroundStyle(Palette.inkMuted(scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Distribuição

    private var distributionPanel: some View {
        let cutoff = Date().addingTimeInterval(-Double(period.days) * 86_400)
        let valid = readings.filter { $0.validity == .valid && $0.timestamp >= cutoff }
        let buckets: [(String, ClosedRange<Int>)] = [
            ("Abaixo de 110", 0...109),
            ("110 a 119", 110...119),
            ("120 a 129", 120...129),
            ("130 a 139", 130...139),
            ("140 ou mais", 140...400),
        ]

        return VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Distribuição das leituras",
                           subtitle: "Sistólica, por faixa. Contagem de leituras "
                                   + "no período.")
            Panel {
                if valid.isEmpty {
                    Text(TrendAnalysis.insufficientData)
                        .font(.body)
                        .foregroundStyle(Palette.inkMuted(scheme))
                } else {
                    DistributionBars(items: buckets.map { label, range in
                        .init(id: label, label: label,
                              value: Double(valid.filter { range.contains($0.systolic) }.count),
                              unitSuffix: "leituras")
                    })
                }
            }
        }
    }

    // MARK: - Tabela

    private var readingsTable: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Leituras recentes")
            Panel {
                if readings.isEmpty {
                    Text("Nenhuma leitura registrada.")
                        .font(.body)
                        .foregroundStyle(Palette.inkMuted(scheme))
                } else {
                    ForEach(readings.prefix(20)) { reading in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(reading.systolic)/\(reading.diastolic)")
                                    .font(.body.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.ink(scheme))
                                if let pulse = reading.pulse {
                                    Text("· \(pulse) bpm")
                                        .font(.subheadline)
                                        .monospacedDigit()
                                        .foregroundStyle(Palette.inkSecondary(scheme))
                                }
                                Spacer()
                                Text(Format.dayAndTime.string(from: reading.timestamp))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.inkMuted(scheme))
                            }
                            HStack(spacing: 8) {
                                Text(reading.source.label)
                                if let step = reading.protocolStep {
                                    Text("· Medida \(step)")
                                }
                                if reading.validity != .valid {
                                    Text("· \(reading.validity.label)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(Palette.inkMuted(scheme))
                            if let notes = reading.notes, !notes.isEmpty {
                                Text(notes)
                                    .font(.caption)
                                    .foregroundStyle(Palette.inkSecondary(scheme))
                            }
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                        if reading.id != readings.prefix(20).last?.id {
                            Divider().overlay(Palette.hairline(scheme))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Importação

    private func importFromHealth() async {
        guard health.status == .authorized else { return }
        let samples = await health.fetchPressure()
        guard !samples.isEmpty else { return }

        let existing = Set(readings.map { $0.timestamp.timeIntervalSince1970.rounded() })
        var added = 0
        for sample in samples {
            let key = sample.timestamp.timeIntervalSince1970.rounded()
            guard !existing.contains(key) else { continue }
            let reading = BloodPressureReading(
                timestamp: sample.timestamp, systolic: sample.systolic,
                diastolic: sample.diastolic,
                source: sample.isCuff ? .cuff : .manual)
            reading.cuffModel = sample.isCuff ? sample.sourceName : nil
            reading.notes = sample.isCuff ? nil
                : "Origem \(sample.sourceName): fora da série padronizada de manguito."
            context.insert(reading)
            added += 1
        }
        if added > 0 { try? context.save() }
        importMessage = added > 0
            ? "\(added) leituras importadas da Saúde."
            : nil
    }
}

// MARK: - Fluxo guiado

/// Conduz as etapas do protocolo e salva a sessão com a aderência real.
struct MorningProtocolView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let sessionType: BPSessionType

    @State private var currentStep = 1
    @State private var entries: [Int: (sys: String, dia: String, pulse: String)] = [:]
    @State private var arm: CuffArm = .left
    @State private var waitRemaining = 0
    @State private var timer: Timer?
    @State private var notes = ""

    // Contexto opcional
    @State private var sleepPoor = false
    @State private var alcoholPreviousDay = false
    @State private var intenseTraining = false
    @State private var earlyCaffeine = false
    @State private var perceivedStress = false
    @State private var illness = false
    @State private var pain = false
    @State private var medicationTaken = false

    private var steps: [MorningProtocol.Step] {
        sessionType == .morningReference
            ? MorningProtocol.steps
            : [.init(id: 1, text: "Sente-se e repouse por alguns minutos.",
                     waitSeconds: 0, capturesReading: false),
               .init(id: 2, text: "Fazer a medida.", waitSeconds: 0,
                     capturesReading: true)]
    }

    private var readingSteps: [MorningProtocol.Step] {
        steps.filter(\.capturesReading)
    }

    private var completedReadings: Int {
        readingSteps.filter { parsed($0.id) != nil }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(sessionType == .morningReference
                         ? MorningProtocol.guidance
                         : MorningProtocol.nightGuidance)
                        .font(.subheadline)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)

                    Picker("Braço", selection: $arm) {
                        Text("Esquerdo").tag(CuffArm.left)
                        Text("Direito").tag(CuffArm.right)
                    }
                    .pickerStyle(.segmented)

                    ForEach(steps) { step in
                        stepPanel(step)
                    }

                    if sessionType == .morningReference { contextPanel }

                    Panel {
                        Text("Observações")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Palette.inkSecondary(scheme))
                        TextField("Opcional", text: $notes, axis: .vertical)
                            .lineLimit(2...5)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(Palette.surfaceRaised(scheme),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }

                    summaryPanel

                    Text(MorningProtocol.conductNotice)
                        .font(.caption)
                        .foregroundStyle(Palette.inkMuted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.background(scheme))
            .navigationTitle(sessionType.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { stopTimer(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") { save() }
                        .disabled(completedReadings == 0)
                }
            }
            .onDisappear { stopTimer() }
        }
    }

    @ViewBuilder
    private func stepPanel(_ step: MorningProtocol.Step) -> some View {
        Panel {
            HStack(alignment: .top, spacing: 10) {
                Text("\(step.id)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkMuted(scheme))
                    .frame(width: 20, alignment: .trailing)
                Text(step.text)
                    .font(.body)
                    .foregroundStyle(Palette.ink(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if step.capturesReading {
                HStack(spacing: 10) {
                    numberField("Sistólica", step.id, \.sys)
                    numberField("Diastólica", step.id, \.dia)
                    numberField("Pulso", step.id, \.pulse)
                }
            }

            if step.waitSeconds > 0 {
                if currentStep == step.id && waitRemaining > 0 {
                    Text("Aguardando \(waitRemaining)s")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.neutral(scheme))
                } else {
                    Button("Iniciar espera de \(step.waitSeconds / 60 >= 1 ? "\(step.waitSeconds / 60) min" : "\(step.waitSeconds)s")") {
                        startWait(step)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.neutral(scheme))
                }
            }
        }
    }

    @ViewBuilder
    private func numberField(_ title: String, _ stepID: Int,
                             _ key: WritableKeyPath<(sys: String, dia: String,
                                                     pulse: String), String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Palette.inkMuted(scheme))
            TextField("—", text: Binding(
                get: { (entries[stepID] ?? ("", "", ""))[keyPath: key] },
                set: { newValue in
                    var current = entries[stepID] ?? ("", "", "")
                    current[keyPath: key] = newValue
                    entries[stepID] = current
                }))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .padding(10)
                .background(Palette.surfaceRaised(scheme),
                            in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var contextPanel: some View {
        Panel {
            Text("Contexto opcional")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.inkSecondary(scheme))
            Toggle("Sono ruim", isOn: $sleepPoor)
            Toggle("Álcool no dia anterior", isOn: $alcoholPreviousDay)
            Toggle("Treino intenso", isOn: $intenseTraining)
            Toggle("Cafeína precoce", isOn: $earlyCaffeine)
            Toggle("Estresse percebido", isOn: $perceivedStress)
            Toggle("Doença", isOn: $illness)
            Toggle("Dor", isOn: $pain)
            Toggle("Medicação tomada", isOn: $medicationTaken)
        }
        .font(.subheadline)
        .tint(Palette.neutral(scheme))
    }

    private var summaryPanel: some View {
        Panel {
            Text("Resumo da sessão")
                .font(.headline)
                .foregroundStyle(Palette.ink(scheme))

            let values = readingSteps.compactMap { parsed($0.id) }
            if values.isEmpty {
                Text("Registre ao menos uma medida.")
                    .font(.body)
                    .foregroundStyle(Palette.inkMuted(scheme))
            } else {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    HStack {
                        Text("Medida \(index + 1)")
                            .foregroundStyle(Palette.inkSecondary(scheme))
                        Spacer()
                        Text("\(value.sys)/\(value.dia)"
                             + (value.pulse.map { " · \($0) bpm" } ?? ""))
                            .monospacedDigit()
                            .foregroundStyle(Palette.ink(scheme))
                    }
                    .font(.subheadline)
                }

                Divider().overlay(Palette.hairline(scheme))

                let sys = Baseline.mean(values.map { Double($0.sys) }) ?? 0
                let dia = Baseline.mean(values.map { Double($0.dia) }) ?? 0
                let pulses = values.compactMap { $0.pulse.map(Double.init) }

                HStack {
                    Text("Média").font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.inkSecondary(scheme))
                    Spacer()
                    Text("\(Format.decimal(sys, 0))/\(Format.decimal(dia, 0)) mmHg")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink(scheme))
                }
                if let pulseAverage = Baseline.mean(pulses) {
                    HStack {
                        Text("Pulso médio").font(.subheadline)
                            .foregroundStyle(Palette.inkSecondary(scheme))
                        Spacer()
                        Text("\(Format.decimal(pulseAverage, 0)) bpm")
                            .monospacedDigit()
                            .foregroundStyle(Palette.ink(scheme))
                    }
                    .font(.subheadline)
                }
                MetaTag(text: "Aderência ao protocolo: "
                            + Format.percent(adherence * 100))
            }
        }
    }

    private func parsed(_ stepID: Int) -> (sys: Int, dia: Int, pulse: Int?)? {
        guard let entry = entries[stepID],
              let sys = Int(entry.sys), let dia = Int(entry.dia),
              sys > 40, sys < 300, dia > 20, dia < 200 else { return nil }
        return (sys, dia, Int(entry.pulse))
    }

    private var adherence: Double {
        guard !readingSteps.isEmpty else { return 0 }
        return Double(completedReadings) / Double(readingSteps.count)
    }

    private func startWait(_ step: MorningProtocol.Step) {
        stopTimer()
        currentStep = step.id
        waitRemaining = step.waitSeconds
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if waitRemaining > 0 {
                waitRemaining -= 1
            } else {
                stopTimer()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func save() {
        let values = readingSteps.enumerated().compactMap { index, step in
            parsed(step.id).map { (index: index + 1, value: $0) }
        }
        guard !values.isEmpty else { return }

        let sessionID = UUID()
        let now = Date()
        let sys = Baseline.mean(values.map { Double($0.value.sys) }) ?? 0
        let dia = Baseline.mean(values.map { Double($0.value.dia) }) ?? 0
        let pulses = values.compactMap { $0.value.pulse.map(Double.init) }

        let session = BloodPressureSession(
            id: sessionID, date: now, type: sessionType,
            averageSystolic: sys, averageDiastolic: dia,
            averagePulse: Baseline.mean(pulses), adherence: adherence)
        session.notes = notes.isEmpty ? nil : notes
        session.contextSleepPoor = sleepPoor
        session.contextAlcoholPreviousDay = alcoholPreviousDay
        session.contextIntenseTraining = intenseTraining
        session.contextEarlyCaffeine = earlyCaffeine
        session.contextPerceivedStress = perceivedStress
        session.contextIllness = illness
        session.contextPain = pain
        session.contextMedicationTaken = medicationTaken
        context.insert(session)

        for entry in values {
            let reading = BloodPressureReading(
                timestamp: now, systolic: entry.value.sys,
                diastolic: entry.value.dia, pulse: entry.value.pulse,
                source: .cuff, arm: arm, cuffModel: "Manguito de braço",
                protocolStep: entry.index, sessionID: sessionID)
            context.insert(reading)
        }

        try? context.save()
        stopTimer()
        dismiss()
    }
}
