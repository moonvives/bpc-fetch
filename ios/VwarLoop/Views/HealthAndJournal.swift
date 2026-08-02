import SwiftData
import SwiftUI

struct HealthHubView: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var health: AppleHealthSource

    var body: some View {
        NavigationStack {
            List {
                Section {
                    link("Pressão arterial", "Medidas de manguito e tendência") {
                        BloodPressureView()
                    }
                    link("Sono", "Duração, regularidade e estágios") { SleepView() }
                    link("Exames", "Painéis, séries e intervalos do laudo") {
                        LabsView()
                    }
                    link("Qualidade dos dados", "Fonte, cobertura e confiança") {
                        DataQualityView()
                    }
                    link("Quando procurar ajuda", "Sintomas que pedem avaliação") {
                        SafetyView()
                    }
                }

                Section("Fontes") {
                    sourceRow
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle("Saúde")
        }
    }

    @ViewBuilder
    private func link<Destination: View>(_ title: String, _ subtitle: String,
                                         @ViewBuilder to: () -> Destination) -> some View {
        NavigationLink {
            to()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption)
                    .foregroundStyle(Palette.inkMuted(scheme))
            }
            .padding(.vertical, 4)
        }
    }

    private var sourceRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch health.status {
            case .notRequested:
                Text("Conecte a Saúde da Apple para importar sono, atividade, "
                   + "frequência cardíaca e as leituras do manguito.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary(scheme))
                Button("Conectar Saúde da Apple") {
                    Task { await health.requestAuthorization() }
                }
                .font(.subheadline.weight(.semibold))
            case .authorized:
                Text("Saúde da Apple conectada.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary(scheme))
            case .unavailable:
                Text("Saúde indisponível neste aparelho.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkMuted(scheme))
            case .entitlementMissing:
                Text("Este build foi assinado sem a permissão de Saúde. As demais "
                   + "áreas continuam funcionando com registro manual.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.attention(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Text(message).font(.subheadline)
                    .foregroundStyle(Palette.inkMuted(scheme))
            }

            Text("Strava: as sessões chegam pela Saúde quando a integração está "
               + "ativa no aplicativo do serviço.")
                .font(.caption)
                .foregroundStyle(Palette.inkMuted(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Sono

struct SleepView: View {
    @Environment(\.colorScheme) private var scheme
    @Query(sort: \SleepSession.wakeDay, order: .reverse)
    private var sessions: [SleepSession]
    @Query private var observations: [MetricObservation]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Use tendências de pelo menos duas semanas. Uma noite isolada "
                   + "pode refletir rotina, ambiente, atividade, álcool, doença, "
                   + "dispositivo ou registro incompleto.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                Panel {
                    Text("Duração por noite")
                        .font(.headline)
                        .foregroundStyle(Palette.ink(scheme))
                    SeriesChart(series: [
                        .init(id: "sleep", name: "Sono", unit: "min", decimals: 0,
                              points: Query.sleepMinutes(sessions).prefix(60).map { $0 },
                              color: { Palette.neutral($0) })
                    ])
                }

                Panel {
                    Text("Regularidade")
                        .font(.headline)
                        .foregroundStyle(Palette.ink(scheme))
                    if let regularity = regularityMinutes {
                        Text("Variação típica do horário de dormir: "
                           + Format.duration(minutes: regularity) + ".")
                            .font(.body)
                            .foregroundStyle(Palette.inkSecondary(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(TrendAnalysis.insufficientData)
                            .font(.body)
                            .foregroundStyle(Palette.inkMuted(scheme))
                    }
                }

                Panel {
                    Text("Noites recentes")
                        .font(.headline)
                        .foregroundStyle(Palette.ink(scheme))
                    if sessions.isEmpty {
                        Text("Nenhuma noite registrada.")
                            .font(.body)
                            .foregroundStyle(Palette.inkMuted(scheme))
                    } else {
                        ForEach(sessions.prefix(14)) { night in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(Format.dayMonth.string(from: night.wakeDay))
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(Palette.ink(scheme))
                                    Spacer()
                                    Text(Format.duration(minutes: night.asleepMinutes))
                                        .font(.body)
                                        .monospacedDigit()
                                        .foregroundStyle(Palette.ink(scheme))
                                }
                                HStack(spacing: 8) {
                                    Text("\(Format.time.string(from: night.bedTime))"
                                       + " às \(Format.time.string(from: night.wakeTime))")
                                    if let efficiency = night.efficiency {
                                        Text("· eficiência "
                                           + Format.percent(efficiency))
                                    }
                                    if night.awakenings > 0 {
                                        Text("· \(night.awakenings) despertares")
                                    }
                                }
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(Palette.inkMuted(scheme))
                            }
                            .padding(.vertical, 5)
                            .accessibilityElement(children: .combine)
                            if night.id != sessions.prefix(14).last?.id {
                                Divider().overlay(Palette.hairline(scheme))
                            }
                        }
                    }
                }

                Text(TrendAnalysis.associationNotice)
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
        .navigationTitle("Sono")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Dispersão dos horários de dormir, em minutos.
    private var regularityMinutes: Double? {
        let recent = sessions.prefix(14)
        guard recent.count >= 5 else { return nil }
        let calendar = Calendar.current
        let minutes = recent.map { session -> Double in
            let comps = calendar.dateComponents([.hour, .minute], from: session.bedTime)
            var value = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
            // Horários após a meia-noite ficam próximos de zero e distorcem a
            // dispersão; desloca para uma escala contínua da noite.
            if value < 720 { value += 1440 }
            return value
        }
        guard let median = Baseline.median(minutes) else { return nil }
        let deviations = minutes.map { abs($0 - median) }
        return Baseline.median(deviations)
    }
}

// MARK: - Exames

struct LabsView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var context
    @Query(sort: \LabResult.collectedAt, order: .reverse)
    private var results: [LabResult]
    @State private var showingEntry = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Organize por finalidade e acompanhe a série ao longo do "
                   + "tempo. O intervalo de referência é o informado pelo "
                   + "laboratório no seu laudo.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    showingEntry = true
                } label: {
                    Text("Adicionar resultado")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .background(Palette.neutral(scheme),
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)

                if !cardiovascularMarkers.isEmpty {
                    SectionHeading(title: "Acompanhamento cardiovascular",
                                   subtitle: "Marcadores priorizados junto da "
                                           + "pressão de manguito e do estilo de vida.")
                    ForEach(cardiovascularMarkers, id: \.self) { marker in
                        markerPanel(marker)
                    }
                }

                ForEach(LabPanel.allCases, id: \.self) { panel in
                    let markers = markersIn(panel)
                    if !markers.isEmpty {
                        SectionHeading(title: panel.label, subtitle: panel.purpose)
                        ForEach(markers, id: \.self) { markerPanel($0) }
                    }
                }

                if results.isEmpty {
                    Panel {
                        Text("Nenhum resultado registrado.")
                            .font(.body)
                            .foregroundStyle(Palette.inkMuted(scheme))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background(scheme))
        .navigationTitle("Exames")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingEntry) { LabEntrySheet() }
    }

    private var cardiovascularMarkers: [Biomarker] {
        Array(Set(results.map(\.marker)).filter(\.isCardiovascularPriority))
            .sorted { $0.label < $1.label }
    }

    private func markersIn(_ panel: LabPanel) -> [Biomarker] {
        Array(Set(results.map(\.marker)).filter { $0.panel == panel })
            .sorted { $0.label < $1.label }
    }

    @ViewBuilder
    private func markerPanel(_ marker: Biomarker) -> some View {
        let series = results.filter { $0.marker == marker }
            .sorted { $0.collectedAt > $1.collectedAt }
        Panel {
            HStack(alignment: .firstTextBaseline) {
                Text(marker.label)
                    .font(.headline)
                    .foregroundStyle(Palette.ink(scheme))
                Spacer()
                if let latest = series.first {
                    Text("\(Format.decimal(latest.value, marker.decimals)) "
                       + marker.unit)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink(scheme))
                }
            }

            if let latest = series.first {
                Text(latest.comparison.label)
                    .font(.subheadline)
                    .foregroundStyle(latest.comparison == .within
                                     ? Palette.inkSecondary(scheme)
                                     : Palette.attention(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                if latest.comparison == .above || latest.comparison == .below {
                    Text(LabResult.outOfRangeGuidance)
                        .font(.caption)
                        .foregroundStyle(Palette.inkMuted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    MetaTag(text: Format.dayMonth.string(from: latest.collectedAt))
                    if let lab = latest.laboratory, !lab.isEmpty {
                        MetaTag(text: lab)
                    }
                    if let low = latest.referenceLow, let high = latest.referenceHigh {
                        MetaTag(text: "Referência \(Format.decimal(low, marker.decimals))"
                                    + "–\(Format.decimal(high, marker.decimals))")
                    } else if let text = latest.referenceText, !text.isEmpty {
                        MetaTag(text: "Referência \(text)")
                    }
                }
            }

            if series.count >= 2 {
                SeriesChart(series: [
                    .init(id: marker.rawValue, name: marker.label,
                          unit: marker.unit, decimals: marker.decimals,
                          points: series.map { (day: $0.collectedAt, value: $0.value) },
                          color: { Palette.neutral($0) })
                ], height: 130)
            }
        }
    }
}

struct LabEntrySheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var marker: Biomarker = .ldl
    @State private var value = ""
    @State private var collectedAt = Date()
    @State private var laboratory = ""
    @State private var referenceLow = ""
    @State private var referenceHigh = ""
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Resultado") {
                    Picker("Marcador", selection: $marker) {
                        ForEach(Biomarker.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    HStack {
                        TextField("Valor", text: $value)
                            .keyboardType(.decimalPad)
                        Text(marker.unit)
                            .foregroundStyle(Palette.inkMuted(scheme))
                    }
                    DatePicker("Coleta", selection: $collectedAt,
                               displayedComponents: .date)
                    TextField("Laboratório", text: $laboratory)
                }

                Section("Intervalo de referência do laudo") {
                    HStack {
                        TextField("Mínimo", text: $referenceLow)
                            .keyboardType(.decimalPad)
                        TextField("Máximo", text: $referenceHigh)
                            .keyboardType(.decimalPad)
                    }
                    Text("Informe o intervalo impresso no seu laudo. O aplicativo "
                       + "não substitui esse intervalo por valores próprios.")
                        .font(.caption)
                        .foregroundStyle(Palette.inkMuted(scheme))
                }

                Section("Observações") {
                    TextField("Opcional", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle("Novo resultado")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") { save() }
                        .disabled(Double(value.replacingOccurrences(of: ",", with: ".")) == nil)
                }
            }
        }
    }

    private func save() {
        guard let parsed = Double(value.replacingOccurrences(of: ",", with: "."))
        else { return }
        let result = LabResult(
            marker: marker, value: parsed, collectedAt: collectedAt,
            laboratory: laboratory.isEmpty ? nil : laboratory,
            referenceLow: Double(referenceLow.replacingOccurrences(of: ",", with: ".")),
            referenceHigh: Double(referenceHigh.replacingOccurrences(of: ",", with: ".")))
        result.notes = notes.isEmpty ? nil : notes
        context.insert(result)
        try? context.save()
        dismiss()
    }
}

// MARK: - Qualidade dos dados

struct DataQualityView: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var health: AppleHealthSource
    @Query private var observations: [MetricObservation]
    @Query private var sleep: [SleepSession]
    @Query private var readings: [BloodPressureReading]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Fonte, cobertura e confiança de cada métrica, antes de "
                   + "qualquer interpretação.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(reports) { report in
                    Panel {
                        HStack(alignment: .firstTextBaseline) {
                            Text(report.metricLabel)
                                .font(.headline)
                                .foregroundStyle(Palette.ink(scheme))
                            Spacer()
                            ConfidenceTag(confidence: report.confidence)
                        }
                        FlowTags(tags: [
                            "\(report.coverageDays)/\(report.periodDays) dias",
                            report.isDirect ? "Medida direta" : "Valor derivado",
                            report.sourceLabel,
                        ])
                        if let last = report.lastReading {
                            Text("Última leitura: "
                               + Format.dayAndTime.string(from: last))
                                .font(.caption)
                                .foregroundStyle(Palette.inkMuted(scheme))
                        }
                        if report.duplicatesDetected > 0 {
                            Text("\(report.duplicatesDetected) leituras duplicadas "
                               + "no período.")
                                .font(.caption)
                                .foregroundStyle(Palette.inkMuted(scheme))
                        }
                        if let gap = report.largestGapDays, gap > 1 {
                            Text("Maior lacuna: \(gap) dias.")
                                .font(.caption)
                                .foregroundStyle(Palette.inkMuted(scheme))
                        }
                        Text(report.rationale)
                            .font(.caption)
                            .foregroundStyle(Palette.inkMuted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SectionHeading(title: "Excluídas da interpretação",
                               subtitle: "Estimativas sem validação para decisão "
                                       + "clínica.")
                ForEach(DataQuality.excluded) { item in
                    Panel {
                        Text(item.label)
                            .font(.headline)
                            .foregroundStyle(Palette.ink(scheme))
                        Text(Confidence.notClinical.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Palette.attention(scheme))
                        Text(item.reason)
                            .font(.subheadline)
                            .foregroundStyle(Palette.inkSecondary(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(DataQuality.excludedNotice)
                            .font(.caption)
                            .foregroundStyle(Palette.inkMuted(scheme))
                    }
                }

                if !health.auditTrail.isEmpty {
                    SectionHeading(title: "Trilha de importações")
                    Panel {
                        ForEach(health.auditTrail.prefix(12), id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(Palette.inkMuted(scheme))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background(scheme))
        .navigationTitle("Qualidade dos dados")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var reports: [DataQualityReport] {
        var out: [DataQualityReport] = []

        for kind in [MetricKind.restingHeartRate, .sleepingHeartRate,
                     .heartRateVariability, .respiratoryRate] {
            let series = Query.dailyValues(observations, kind: kind)
            out.append(DataQuality.report(
                id: kind.rawValue, metricLabel: kind.label,
                days: series.map(\.day), periodDays: 30,
                source: .appleHealth,
                sourceName: Query.sourceName(observations, kind: kind),
                isDirect: false,
                extraRationale: kind == .heartRate
                    ? "Não há informação suficiente de postura ou movimento para "
                    + "classificar as leituras como repouso." : nil))
        }

        out.append(DataQuality.report(
            id: "sleep", metricLabel: "Sono",
            days: sleep.map(\.wakeDay), periodDays: 30,
            source: .appleHealth, sourceName: sleep.first?.sourceName ?? "",
            isDirect: false))

        let cuffReadings = readings.filter { $0.source == .cuff }
        out.append(DataQuality.report(
            id: "pressure", metricLabel: "Pressão arterial",
            days: cuffReadings.map(\.day), periodDays: 30,
            source: .cuff, sourceName: HealthSource.cuff.label, isDirect: true,
            extraRationale: "Confiança alta para a leitura individual quando "
                          + "importada do manguito; a tendência depende de mais "
                          + "sessões padronizadas."))

        return out
    }
}

// MARK: - Segurança

struct SafetyView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(SafetyNotice.headline)
                    .font(.title3)
                    .foregroundStyle(Palette.ink(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                Panel {
                    Text("Procure atendimento com urgência diante de:")
                        .font(.headline)
                        .foregroundStyle(Palette.urgent(scheme))
                    ForEach(SafetyNotice.urgentSymptoms, id: \.self) { symptom in
                        HStack(alignment: .top, spacing: 8) {
                            Text("—").foregroundStyle(Palette.urgent(scheme))
                            Text(symptom)
                                .foregroundStyle(Palette.inkSecondary(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.body)
                    }
                }

                Panel {
                    Text("Medidas fora do seu padrão")
                        .font(.headline)
                        .foregroundStyle(Palette.ink(scheme))
                    Text(SafetyNotice.repeatMeasureGuidance)
                        .font(.body)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Panel {
                    Text("Medicamentos")
                        .font(.headline)
                        .foregroundStyle(Palette.ink(scheme))
                    Text(SafetyNotice.medicationNotice)
                        .font(.body)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background(scheme))
        .navigationTitle("Quando procurar ajuda")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Diário

struct JournalView: View {
    @Environment(\.colorScheme) private var scheme
    @Query(sort: \DailyContextLog.day, order: .reverse)
    private var logs: [DailyContextLog]
    @Query(sort: \MedicationContextLog.takenAt, order: .reverse)
    private var medications: [MedicationContextLog]
    @State private var showingEntry = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Registros de contexto entram como variáveis, não como "
                       + "explicação. Servem para observar padrões e para levar "
                       + "à consulta.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        showingEntry = true
                    } label: {
                        Text("Registrar hoje")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .background(Palette.neutral(scheme),
                                in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)

                    if logs.isEmpty {
                        Panel {
                            Text("Nenhum registro ainda.")
                                .font(.body)
                                .foregroundStyle(Palette.inkMuted(scheme))
                        }
                    } else {
                        ForEach(logs.prefix(30)) { log in
                            Panel {
                                Text(Format.dayMonth.string(from: log.day))
                                    .font(.headline)
                                    .foregroundStyle(Palette.ink(scheme))
                                if !log.tags.isEmpty {
                                    FlowTags(tags: log.tags.map(\.label))
                                }
                                if let stress = log.perceivedStress {
                                    Text("Estresse percebido: \(stress) de 5")
                                        .font(.subheadline)
                                        .foregroundStyle(Palette.inkSecondary(scheme))
                                }
                                if let pain = log.painLevel {
                                    Text("Dor: \(pain) de 10")
                                        .font(.subheadline)
                                        .foregroundStyle(Palette.inkSecondary(scheme))
                                }
                                if let note = log.note, !note.isEmpty {
                                    Text(note)
                                        .font(.subheadline)
                                        .foregroundStyle(Palette.inkSecondary(scheme))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    if !medications.isEmpty {
                        SectionHeading(title: "Medicação")
                        Panel {
                            ForEach(medications.prefix(10)) { entry in
                                HStack {
                                    Text(entry.name)
                                        .foregroundStyle(Palette.ink(scheme))
                                    Spacer()
                                    Text(Format.dayAndTime.string(from: entry.takenAt))
                                        .monospacedDigit()
                                        .foregroundStyle(Palette.inkMuted(scheme))
                                }
                                .font(.subheadline)
                            }
                            Text(MedicationContextLog.notice)
                                .font(.caption)
                                .foregroundStyle(Palette.inkMuted(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.background(scheme))
            .navigationTitle("Diário")
            .sheet(isPresented: $showingEntry) {
                ContextEntrySheet(day: Calendar.current.startOfDay(for: Date()))
            }
        }
    }
}

struct ContextEntrySheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var logs: [DailyContextLog]

    let day: Date

    @State private var selected: Set<ContextTag> = []
    @State private var perceivedStress = 3.0
    @State private var painLevel = 0.0
    @State private var note = ""
    @State private var medicationName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Registros do dia") {
                    ForEach(ContextTag.allCases, id: \.self) { tag in
                        Toggle(tag.label, isOn: Binding(
                            get: { selected.contains(tag) },
                            set: { on in
                                if on { selected.insert(tag) } else { selected.remove(tag) }
                            }))
                    }
                }
                .tint(Palette.neutral(scheme))

                Section("Escalas") {
                    VStack(alignment: .leading) {
                        Text("Estresse percebido: \(Int(perceivedStress)) de 5")
                        Slider(value: $perceivedStress, in: 1...5, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("Dor: \(Int(painLevel)) de 10")
                        Slider(value: $painLevel, in: 0...10, step: 1)
                    }
                }

                Section("Medicação") {
                    TextField("Nome", text: $medicationName)
                    Text(MedicationContextLog.notice)
                        .font(.caption)
                        .foregroundStyle(Palette.inkMuted(scheme))
                }

                Section("Observação livre") {
                    TextField("Opcional", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Contexto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") { save() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let existing = logs.first(where: { $0.day == day }) else { return }
        selected = Set(existing.tags)
        perceivedStress = Double(existing.perceivedStress ?? 3)
        painLevel = Double(existing.painLevel ?? 0)
        note = existing.note ?? ""
    }

    private func save() {
        let log = logs.first { $0.day == day } ?? {
            let created = DailyContextLog(day: day)
            context.insert(created)
            return created
        }()
        log.tags = Array(selected)
        log.perceivedStress = Int(perceivedStress)
        log.painLevel = Int(painLevel)
        log.note = note.isEmpty ? nil : note
        log.updatedAt = Date()

        if !medicationName.isEmpty {
            context.insert(MedicationContextLog(name: medicationName, takenAt: Date()))
        }
        try? context.save()
        dismiss()
    }
}
