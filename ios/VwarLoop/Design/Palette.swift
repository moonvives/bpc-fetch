import SwiftUI

/// Paleta e tipografia. Estética editorial médica: densa, calma, alto contraste.
/// Vermelho é reservado para orientação de urgência clínica e nunca aparece por
/// sono curto, treino perdido ou alimentação.
enum Palette {

    // Superfícies
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x0B0E13) : Color(hex: 0xF7F7F4)
    }
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x141922) : Color(hex: 0xFFFFFF)
    }
    static func surfaceRaised(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1B2230) : Color(hex: 0xF0F1EE)
    }
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x27303E) : Color(hex: 0xD8D9D4)
    }

    // Tinta
    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xF2F4F7) : Color(hex: 0x11141A)
    }
    static func inkSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xBCC4D0) : Color(hex: 0x3D444F)
    }
    static func inkMuted(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x8B95A5) : Color(hex: 0x5F6773)
    }

    // Semântica de tendência
    /// Tendência neutra e séries principais.
    static func neutral(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x5B8DEF) : Color(hex: 0x1F4FA8)
    }
    /// Melhora ou dentro da faixa habitual.
    static func improving(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x3FA795) : Color(hex: 0x0E6B5C)
    }
    /// Atenção e contexto. Não é reprovação.
    static func attention(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xD9A03C) : Color(hex: 0x8A5D07)
    }
    /// Somente orientação de urgência clínica.
    static func urgent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xE0655C) : Color(hex: 0xA32A22)
    }
    /// Segunda série em gráficos com dois traços.
    static func secondarySeries(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x9B8CE8) : Color(hex: 0x4B3D9E)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Direção de uma variação, com significado visual e textual separados.
/// A direção nunca é comunicada só por cor: sempre acompanha texto.
enum ChangeDirection {
    case above, below, stable, unknown

    func tint(_ scheme: ColorScheme) -> Color {
        switch self {
        case .above, .below: return Palette.attention(scheme)
        case .stable: return Palette.improving(scheme)
        case .unknown: return Palette.inkMuted(scheme)
        }
    }
}

/// Formatação compartilhada.
enum Format {

    static func duration(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60
        let m = abs(total % 60)
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h)h" : String(format: "%dh%02d", h, m)
    }

    static func signedMinutes(_ minutes: Double) -> String {
        let sign = minutes >= 0 ? "+" : "−"
        return sign + duration(minutes: abs(minutes))
    }

    static func decimal(_ value: Double, _ places: Int = 0) -> String {
        String(format: "%.\(places)f", value)
    }

    static func signed(_ value: Double, _ places: Int = 0, unit: String = "") -> String {
        let sign = value >= 0 ? "+" : "−"
        let body = String(format: "%.\(places)f", abs(value))
        return unit.isEmpty ? sign + body : "\(sign)\(body) \(unit)"
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "d MMM"
        return f
    }()

    static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "EEEE, d 'de' MMMM"
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dayAndTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "dd/MM HH:mm"
        return f
    }()

    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
