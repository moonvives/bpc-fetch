import SwiftUI

/// Paleta do app. Os mesmos valores do web app, validados para contraste sobre a
/// superficie escura: fundo #0d0d0d, cartao #1a1a19, e as series com contraste
/// suficiente sobre ela.
enum Theme {
    static let bg = Color(hex: 0x0D0D0D)
    static let surface = Color(hex: 0x1A1A19)
    static let surfaceAlt = Color(hex: 0x141413)
    static let line = Color(hex: 0x2C2C2A)
    static let axis = Color(hex: 0x383835)

    static let ink = Color.white
    static let inkSecondary = Color(hex: 0xC3C2B7)
    static let muted = Color(hex: 0x898781)

    static let accent = Color(hex: 0x3987E5)   // azul, serie 1
    static let aqua = Color(hex: 0x199E70)     // serie 2
    static let yellow = Color(hex: 0xC98500)   // serie 3
    static let violet = Color(hex: 0x9085E9)   // serie 5

    static let good = Color(hex: 0x0CA30C)
    static let warning = Color(hex: 0xFAB219)
    static let serious = Color(hex: 0xEC835A)
    static let critical = Color(hex: 0xD03B3B)

    static func color(for band: ScoreEngine.Band) -> Color {
        switch band {
        case .good: return good
        case .warning: return warning
        case .serious: return serious
        case .critical: return critical
        case .unknown: return muted
        }
    }

    static func color(for quality: Provenance.Quality) -> Color {
        switch quality {
        case .reliable: return good
        case .partial: return warning
        case .sparse, .missing: return critical
        }
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

// MARK: - Componentes reutilizados

/// Cartao padrao: superficie elevada com contorno de um pixel.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// Titulo de seção, em caixa alta e discreto.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.4)
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }
}

/// Anel do Recovery Score.
struct RecoveryRing: View {
    let score: Int?
    let band: ScoreEngine.Band
    var size: CGFloat = 172

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.line, lineWidth: 12)
            Circle()
                .trim(from: 0, to: CGFloat(score ?? 0) / 100)
                .stroke(Theme.color(for: band),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.7), value: score)
            VStack(spacing: 4) {
                Text(score.map(String.init) ?? "--")
                    .font(.system(size: size * 0.28, weight: .bold, design: .default))
                    .foregroundStyle(Theme.ink)
                Text("RECOVERY")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.6)
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Bloco de estatística com delta contra a semana anterior.
struct StatTile: View {
    let label: String
    let value: Double?
    let unit: String
    var decimals: Int = 0
    var delta: Double?
    /// Quando verdadeiro, cair é bom (caso da FC de repouso).
    var lowerIsBetter = false

    private var deltaView: some View {
        Group {
            if let delta, abs(delta) >= (decimals > 0 ? 0.05 : 0.5) {
                let improving = lowerIsBetter ? delta < 0 : delta > 0
                Text(String(format: "%@%.\(decimals)f vs. 7d ant.",
                            delta > 0 ? "+" : "", delta))
                    .foregroundStyle(improving ? Theme.good : Theme.critical)
            } else if delta != nil {
                Text("estável").foregroundStyle(Theme.muted)
            }
        }
        .font(.caption)
    }

    var body: some View {
        Card {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { String(format: "%.\(decimals)f", $0) } ?? "--")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text(unit).font(.subheadline).foregroundStyle(Theme.muted)
            }
            deltaView
        }
    }
}
