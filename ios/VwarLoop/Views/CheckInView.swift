import SwiftData
import SwiftUI

/// Check-in diario. Deve levar cerca de 30 segundos.
///
/// Os campos objetivos podem vir da Saude da Apple ou do Bluetooth; os
/// subjetivos so você sabe — e são justamente eles que explicam a maior parte da
/// variação que nenhum sensor captura.
struct CheckInView: View {
    let entries: [DailyEntry]
    @ObservedObject var band: BandManager

    @Environment(\.modelContext) private var context
    @State private var day = Date()
    @State private var saved = false

    // Objetivo
    @State private var sleepHours = ""
    @State private var sleepQuality = 3.0
    @State private var restingHR = ""
    @State private var hrv = ""
    @State private var spo2 = ""
    @State private var weight = ""

    // Subjetivo
    @State private var energy = 3.0
    @State private var stress = 3.0
    @State private var soreness = 2.0
    @State private var focus = 3.0

    // Treino
    @State private var workoutType = ""
    @State private var workoutMinutes = ""
    @State private var workoutIntensity = 3.0

    @State private var notes = ""

    private var editing: DailyEntry? {
        let normalized = Calendar.current.startOfDay(for: day)
        return entries.first { $0.day == normalized }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Dia", selection: $day, displayedComponents: .date)
                }

                Section("Sono e cardiovascular") {
                    numberField("Sono (horas)", $sleepHours, "7.5")
                    scaleRow("Qualidade do sono", $sleepQuality)
                    numberField("FC de repouso (bpm)", $restingHR, "62")
                    numberField("HRV / RMSSD (ms)", $hrv, "55")
                    numberField("SpO2 (%)", $spo2, "97")
                    numberField("Peso (kg)", $weight, "")
                }

                Section("Como você está") {
                    scaleRow("Energia", $energy)
                    scaleRow("Estresse", $stress, inverted: true)
                    scaleRow("Dor muscular", $soreness, inverted: true)
                    scaleRow("Foco / produtividade", $focus)
                }

                Section("Treino") {
                    TextField("Tipo", text: $workoutType,
                              prompt: Text("corrida, força, mobilidade..."))
                    numberField("Duração (min)", $workoutMinutes, "45")
                    scaleRow("Intensidade", $workoutIntensity)
                }

                Section("Notas") {
                    TextField("O que aconteceu hoje", text: $notes,
                              axis: .vertical)
                        .lineLimit(3...6)
                }

                liveSection

                Section {
                    Button(saved ? "Salvo" : "Salvar dia") { save() }
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                        .disabled(saved)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Check-in")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: load)
            .onChange(of: day) { _, _ in load() }
        }
    }

    /// Leitura ao vivo pela pulseira. Aparece com o valor pronto para copiar
    /// para o campo de HRV — sem digitação e sem depender do G Band.
    @ViewBuilder
    private var liveSection: some View {
        Section("Pulseira") {
            HStack {
                Text(band.state.label)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                Spacer()
                if case .connected = band.state {
                    Button("Desconectar") { band.stop() }.font(.caption)
                } else {
                    Button("Conectar") { band.start() }.font(.caption)
                }
            }

            if let hr = band.heartRate {
                LabeledContent("Frequência cardíaca", value: "\(hr) bpm")
            }
            if let level = band.battery {
                LabeledContent("Bateria da pulseira", value: "\(level)%")
            }
            if let live = band.liveRMSSD {
                LabeledContent("RMSSD ao vivo",
                               value: String(format: "%.1f ms (%d RR)", live, band.rrCount))
                Button("Usar como HRV de hoje") {
                    hrv = String(format: "%.0f", band.sessionRMSSD ?? live)
                }
                .font(.caption)
            }
            if case .connected = band.state, !band.speaksStandardHeartRate {
                Text("Esta pulseira não expõe o serviço padrão de frequência "
                   + "cardíaca. Os pacotes brutos estão sendo gravados para "
                   + "engenharia reversa — veja a aba Dados.")
                    .font(.caption2).foregroundStyle(Theme.muted)
            }
        }
    }

    private func numberField(_ label: String, _ text: Binding<String>,
                             _ placeholder: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
        }
    }

    /// Escala de 1 a 5. Em campos invertidos (estresse, dor), 5 é ruim — o rótulo
    /// diz isso para não haver ambiguidade na hora de preencher.
    private func scaleRow(_ label: String, _ value: Binding<Double>,
                          inverted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue))")
                    .foregroundStyle(Theme.muted).monospacedDigit()
            }
            Slider(value: value, in: 1...5, step: 1)
            Text(inverted ? "1 = nada  ·  5 = muito" : "1 = baixo  ·  5 = alto")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
    }

    private func load() {
        saved = false
        guard let entry = editing else {
            sleepHours = ""; restingHR = ""; hrv = ""; spo2 = ""; weight = ""
            workoutType = ""; workoutMinutes = ""; notes = ""
            sleepQuality = 3; energy = 3; stress = 3; soreness = 2; focus = 3
            workoutIntensity = 3
            return
        }
        sleepHours = entry.sleepHours.map { String(format: "%.1f", $0) } ?? ""
        restingHR = entry.restingHR.map { String(format: "%.0f", $0) } ?? ""
        hrv = entry.hrv.map { String(format: "%.0f", $0) } ?? ""
        spo2 = entry.spo2.map { String(format: "%.0f", $0) } ?? ""
        weight = entry.weight.map { String(format: "%.1f", $0) } ?? ""
        workoutType = entry.workoutType ?? ""
        workoutMinutes = entry.workoutMinutes.map { String(format: "%.0f", $0) } ?? ""
        notes = entry.notes ?? ""
        sleepQuality = entry.sleepQuality ?? 3
        energy = entry.energy ?? 3
        stress = entry.stress ?? 3
        soreness = entry.soreness ?? 2
        focus = entry.focus ?? 3
        workoutIntensity = entry.workoutIntensity ?? 3
    }

    private func save() {
        let entry = EntryStore.entry(for: day, in: context, existing: entries)
        entry.sleepHours = Double(sleepHours.replacingOccurrences(of: ",", with: "."))
        entry.restingHR = Double(restingHR.replacingOccurrences(of: ",", with: "."))
        entry.hrv = Double(hrv.replacingOccurrences(of: ",", with: "."))
        entry.spo2 = Double(spo2.replacingOccurrences(of: ",", with: "."))
        entry.weight = Double(weight.replacingOccurrences(of: ",", with: "."))
        entry.workoutMinutes = Double(workoutMinutes.replacingOccurrences(of: ",", with: "."))
        entry.workoutType = workoutType.isEmpty ? nil : workoutType
        entry.workoutIntensity = entry.workoutMinutes == nil ? nil : workoutIntensity
        entry.sleepQuality = sleepQuality
        entry.energy = energy
        entry.stress = stress
        entry.soreness = soreness
        entry.focus = focus
        entry.notes = notes.isEmpty ? nil : notes
        entry.updatedAt = Date()
        try? context.save()
        saved = true
    }
}
