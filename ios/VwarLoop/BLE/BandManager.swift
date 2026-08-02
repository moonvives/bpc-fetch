import CoreBluetooth
import Foundation

/// Matematica de HRV a partir de intervalos entre batimentos.
///
/// RMSSD e o que WHOOP e Oura reportam como "HRV". Ele exige intervalos RR — o
/// tempo entre batimentos consecutivos — que so chegam se a pulseira expuser o
/// campo RR do servico padrao de Heart Rate. Um numero de "HRV" que a banda
/// entrega pronto e caixa-preta; este e calculavel e auditavel.
enum HRVMath {

    /// Raiz da media dos quadrados das diferencas sucessivas, em ms.
    static func rmssd(_ rrIntervals: [Double]) -> Double? {
        let clean = filterArtifacts(rrIntervals)
        guard clean.count >= 2 else { return nil }
        var sumSquares = 0.0
        for i in 1..<clean.count {
            let d = clean[i] - clean[i - 1]
            sumSquares += d * d
        }
        let value = (sumSquares / Double(clean.count - 1)).squareRoot()
        return (value * 10).rounded() / 10
    }

    /// SDNN — desvio padrao dos intervalos. E o que a Saude da Apple guarda como
    /// HRV, entao serve para comparar com o que vem do HealthKit.
    static func sdnn(_ rrIntervals: [Double]) -> Double? {
        let clean = filterArtifacts(rrIntervals)
        guard clean.count >= 2 else { return nil }
        let mean = clean.reduce(0, +) / Double(clean.count)
        let variance = clean.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(clean.count - 1)
        return (variance.squareRoot() * 10).rounded() / 10
    }

    /// Remove artefatos: batimentos fora da faixa fisiologica e saltos maiores
    /// que 20% em relacao ao anterior (tipicamente movimento ou perda de contato
    /// do sensor optico). Sem esta limpeza, um unico artefato infla o RMSSD e
    /// vira "recuperacao excelente" numa noite ruim.
    static func filterArtifacts(_ rr: [Double]) -> [Double] {
        let plausible = rr.filter { $0 >= 300 && $0 <= 2000 }  // 30-200 bpm
        guard var previous = plausible.first else { return [] }
        var out = [previous]
        for value in plausible.dropFirst() {
            if abs(value - previous) / previous <= 0.20 {
                out.append(value)
                previous = value
            }
        }
        return out
    }
}

/// Conexao direta com a pulseira por Bluetooth LE.
///
/// Duas capacidades:
///
/// 1. **Servico padrao de Heart Rate (0x180D).** Se a banda o expuser, FC e
///    intervalos RR chegam prontos, sem decodificar nada — e da para calcular
///    RMSSD de verdade.
/// 2. **Captura de pacotes crus.** Se a banda so falar o protocolo proprietario
///    da JieLi, os pacotes de qualquer caracteristica de notificacao sao gravados
///    em hexadecimal para engenharia reversa, na mesma metodologia do script
///    `tools/vwar_ble.py`.
///
/// Nota: para conectar aqui, desconecte a pulseira do G Band. Uma banda BLE
/// aceita uma conexao central por vez.
@MainActor
final class BandManager: NSObject, ObservableObject {

    struct Packet: Identifiable {
        let id = UUID()
        let at: Date
        let characteristic: String
        let hex: String
        let bytes: Int
    }

    enum State: Equatable {
        case idle, poweredOff, unauthorized, scanning, connecting
        case connected(String), disconnected

        var label: String {
            switch self {
            case .idle: return "Pronto"
            case .poweredOff: return "Bluetooth desligado"
            case .unauthorized: return "Permissão de Bluetooth negada"
            case .scanning: return "Procurando pulseira..."
            case .connecting: return "Conectando..."
            case .connected(let name): return "Conectado a \(name)"
            case .disconnected: return "Desconectado"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var heartRate: Int?
    @Published private(set) var battery: Int?
    @Published private(set) var liveRMSSD: Double?
    @Published private(set) var rrCount = 0
    @Published private(set) var packets: [Packet] = []
    @Published private(set) var discoveredNames: [String] = []
    /// Verdadeiro quando a banda expoe 0x180D — isto e, quando NAO precisamos
    /// decodificar protocolo proprietario.
    @Published private(set) var speaksStandardHeartRate = false

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rrBuffer: [Double] = []

    private static let heartRateService = CBUUID(string: "180D")
    private static let heartRateMeasurement = CBUUID(string: "2A37")
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")
    private static let nameHints = ["vwar", "loop", "gband", "g-band"]

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            beginScan()
        }
    }

    func stop() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central?.stopScan()
        state = .disconnected
    }

    /// Media dos RR da sessao, pronta para virar o campo HRV do check-in.
    var sessionRMSSD: Double? { HRVMath.rmssd(rrBuffer) }

    /// Log em hexadecimal, no mesmo formato que `tools/vwar_ble.py analyze` lê.
    func exportPacketLog() -> String {
        packets.map { p in
            let t = ISO8601DateFormatter().string(from: p.at)
            return #"{"t":"\#(t)","uuid":"\#(p.characteristic)","len":\#(p.bytes),"hex":"\#(p.hex)"}"#
        }.joined(separator: "\n")
    }

    private func beginScan() {
        guard central?.state == .poweredOn else { return }
        discoveredNames = []
        state = .scanning
        // nil = todos os servicos. A VWAR nao anuncia 0x180D no advertisement,
        // entao filtrar por servico faria ela nunca aparecer.
        central?.scanForPeripherals(withServices: nil, options: nil)
    }
}

// MARK: - CBCentralManagerDelegate

extension BandManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: beginScan()
            case .poweredOff: state = .poweredOff
            case .unauthorized: state = .unauthorized
            default: state = .idle
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "")
        guard !name.isEmpty else { return }
        let lower = name.lowercased()
        let matches = Self.nameHints.contains { lower.contains($0) }

        Task { @MainActor in
            if !self.discoveredNames.contains(name) {
                self.discoveredNames.append(name)
            }
            guard matches, self.peripheral == nil else { return }
            self.peripheral = peripheral
            peripheral.delegate = self
            self.state = .connecting
            central.stopScan()
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? "pulseira"
        Task { @MainActor in
            self.state = .connected(name)
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.peripheral = nil
            self.state = .disconnected
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BandManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        var sawStandardHR = false
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.heartRateMeasurement { sawStandardHR = true }
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.uuid == Self.batteryLevel {
                peripheral.readValue(for: characteristic)
            }
        }
        if sawStandardHR {
            Task { @MainActor in self.speaksStandardHeartRate = true }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        let hex = data.map { String(format: "%02x", $0) }.joined()

        Task { @MainActor in
            switch uuid {
            case Self.heartRateMeasurement:
                let reading = Self.parseHeartRate(data)
                self.heartRate = reading.bpm
                if !reading.rrIntervals.isEmpty {
                    self.rrBuffer.append(contentsOf: reading.rrIntervals)
                    if self.rrBuffer.count > 600 {
                        self.rrBuffer.removeFirst(self.rrBuffer.count - 600)
                    }
                    self.rrCount = self.rrBuffer.count
                    self.liveRMSSD = HRVMath.rmssd(Array(self.rrBuffer.suffix(120)))
                }
            case Self.batteryLevel:
                self.battery = data.first.map(Int.init)
            default:
                // Protocolo proprietario: guarda cru para engenharia reversa.
                self.packets.append(.init(at: Date(), characteristic: uuid.uuidString,
                                          hex: hex, bytes: data.count))
                if self.packets.count > 500 { self.packets.removeFirst(100) }
            }
        }
    }

    /// Decodifica o 0x2A37 (Heart Rate Measurement, Bluetooth SIG).
    ///
    /// Bit 0 do flag diz se a FC e uint8 ou uint16; bit 3 indica campo de energia
    /// presente; bit 4 indica intervalos RR, em unidades de 1/1024 s.
    static func parseHeartRate(_ data: Data) -> (bpm: Int, rrIntervals: [Double]) {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return (0, []) }
        var index = 1
        var bpm = 0

        if flags & 0x01 != 0 {
            guard bytes.count >= index + 2 else { return (0, []) }
            bpm = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2
        } else {
            guard bytes.count > index else { return (0, []) }
            bpm = Int(bytes[index])
            index += 1
        }

        if flags & 0x08 != 0 { index += 2 }  // energia gasta

        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while index + 1 < bytes.count {
                let raw = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
                rr.append(Double(raw) / 1024.0 * 1000.0)
                index += 2
            }
        }
        return (bpm, rr)
    }
}
