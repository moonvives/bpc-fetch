import SwiftUI

/// Superfície padrão. Sem sombra, sem gradiente: contorno de um ponto e fundo
/// elevado, no espírito de relatório impresso.
struct Panel<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Palette.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Palette.hairline(scheme), lineWidth: 1))
    }
}

/// Cabeçalho de seção editorial.
struct SectionHeading: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.ink(scheme))
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Etiqueta de confiança. Sempre acompanha texto — nunca comunica só por cor.
struct ConfidenceTag: View {
    @Environment(\.colorScheme) private var scheme
    let confidence: Confidence

    private var tint: Color {
        switch confidence {
        case .high: return Palette.improving(scheme)
        case .moderate: return Palette.neutral(scheme)
        case .low: return Palette.attention(scheme)
        case .notClinical: return Palette.inkMuted(scheme)
        }
    }

    var body: some View {
        Text("Confiança: \(confidence.label)")
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
            .accessibilityLabel("Confiança \(confidence.label)")
    }
}

/// Etiqueta neutra de metadado.
struct MetaTag: View {
    @Environment(\.colorScheme) private var scheme
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Palette.inkSecondary(scheme))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Palette.surfaceRaised(scheme), in: Capsule())
    }
}

/// Linha de leitura de uma métrica: valor grande, comparação e limitação.
struct TrendRow: View {
    @Environment(\.colorScheme) private var scheme
    let trend: TrendAnalysis
    var showLimitations = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(trend.metricLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.inkSecondary(scheme))

            if trend.confidence.supportsInterpretation, let value = trend.currentValue {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.decimal(value, trend.decimals))
                        .font(.system(.largeTitle, design: .default).weight(.semibold))
                        .foregroundStyle(Palette.ink(scheme))
                        .monospacedDigit()
                    Text(trend.unit)
                        .font(.body)
                        .foregroundStyle(Palette.inkMuted(scheme))
                }
                if let delta = trend.deltaAbsolute, trend.direction != .unknown {
                    Text(deltaSentence(delta))
                        .font(.subheadline)
                        .foregroundStyle(trend.direction.tint(scheme))
                }
            } else {
                Text(TrendAnalysis.insufficientData)
                    .font(.body)
                    .foregroundStyle(Palette.inkMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showLimitations, !trend.limitations.isEmpty {
                Text(trend.limitations.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(Palette.inkMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(trend.metricLabel)
        .accessibilityValue(trend.statement)
    }

    private func deltaSentence(_ delta: Double) -> String {
        switch trend.direction {
        case .stable:
            return "Próximo da sua mediana de \(trend.period.days) dias."
        case .above:
            return "\(Format.signed(delta, trend.decimals, unit: trend.unit)) versus "
                 + "sua mediana de \(trend.period.days) dias."
        case .below:
            return "\(Format.signed(delta, trend.decimals, unit: trend.unit)) versus "
                 + "sua mediana de \(trend.period.days) dias."
        case .unknown:
            return ""
        }
    }
}

/// Insight no formato fixo, com as seções sempre visíveis e separadas.
struct InsightPanel: View {
    @Environment(\.colorScheme) private var scheme
    let insight: Insight

    var body: some View {
        Panel {
            Text(insight.title)
                .font(.headline)
                .foregroundStyle(Palette.ink(scheme))
                .fixedSize(horizontal: false, vertical: true)

            ConfidenceTag(confidence: insight.confidence)

            block(Insight.sectionTitles.observed, insight.observed)
            block(Insight.sectionTitles.comparison, insight.comparison)
            if let related = insight.related {
                block(Insight.sectionTitles.related, related)
            }
            block(Insight.sectionTitles.limitations, insight.limitations)
            block(Insight.sectionTitles.nextStep, insight.nextStep)
        }
    }

    @ViewBuilder
    private func block(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(Palette.inkMuted(scheme))
            Text(body)
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Gráfico de linha com escala explícita e tabela equivalente para leitores de
/// tela. Aceita uma ou duas séries.
struct SeriesChart: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Series: Identifiable {
        let id: String
        let name: String
        let unit: String
        let decimals: Int
        let points: [(day: Date, value: Double)]
        let color: (ColorScheme) -> Color
    }

    let series: [Series]
    var height: CGFloat = 170
    @State private var showTable = false

    private var allValues: [Double] { series.flatMap { $0.points.map(\.value) } }
    private var hasEnough: Bool { series.contains { $0.points.count >= 2 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if series.count > 1 {
                HStack(spacing: 14) {
                    ForEach(series) { s in
                        HStack(spacing: 6) {
                            Rectangle()
                                .fill(s.color(scheme))
                                .frame(width: 14, height: 2.5)
                            Text(s.name)
                                .font(.caption)
                                .foregroundStyle(Palette.inkSecondary(scheme))
                        }
                    }
                }
            }

            if !hasEnough {
                Text(TrendAnalysis.insufficientData)
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkMuted(scheme))
                    .frame(maxWidth: .infinity, minHeight: height, alignment: .center)
            } else {
                canvas
                scaleLabels
            }

            Button(showTable ? "Ocultar tabela" : "Ver tabela equivalente") {
                withAnimation(reduceMotion ? nil : .easeInOut) { showTable.toggle() }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Palette.neutral(scheme))

            if showTable { table }
        }
    }

    private var bounds: (min: Double, max: Double) {
        let lo = allValues.min() ?? 0
        let hi = allValues.max() ?? 1
        if hi - lo < 0.0001 { return (lo - 1, hi + 1) }
        let pad = (hi - lo) * 0.12
        return (lo - pad, hi + pad)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let b = bounds
            let span = b.max - b.min
            ZStack {
                ForEach([0.0, 0.5, 1.0], id: \.self) { f in
                    Path { p in
                        let y = geo.size.height * f
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Palette.hairline(scheme), lineWidth: 1)
                }
                ForEach(series) { s in
                    let pts = s.points.sorted { $0.day < $1.day }
                    Path { p in
                        for (i, pt) in pts.enumerated() {
                            let x = pts.count == 1 ? geo.size.width / 2
                                : geo.size.width * CGFloat(i) / CGFloat(pts.count - 1)
                            let y = geo.size.height
                                * CGFloat(1 - (pt.value - b.min) / span)
                            i == 0 ? p.move(to: CGPoint(x: x, y: y))
                                   : p.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    .stroke(s.color(scheme),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                               lineJoin: .round))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var scaleLabels: some View {
        HStack {
            Text("\(Format.decimal(bounds.min, series.first?.decimals ?? 0)) a "
               + "\(Format.decimal(bounds.max, series.first?.decimals ?? 0)) "
               + (series.first?.unit ?? ""))
            Spacer()
            if let first = series.first?.points.sorted(by: { $0.day < $1.day }).first,
               let last = series.first?.points.sorted(by: { $0.day < $1.day }).last {
                Text("\(Format.dayMonth.string(from: first.day)) a "
                   + "\(Format.dayMonth.string(from: last.day))")
            }
        }
        .font(.caption2)
        .foregroundStyle(Palette.inkMuted(scheme))
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(series) { s in
                Text(s.name).font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.inkSecondary(scheme))
                ForEach(s.points.sorted { $0.day > $1.day }.prefix(14), id: \.day) { pt in
                    HStack {
                        Text(Format.dayMonth.string(from: pt.day))
                        Spacer()
                        Text("\(Format.decimal(pt.value, s.decimals)) \(s.unit)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary(scheme))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised(scheme), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Barras horizontais de distribuição, sem rotular faixa como boa ou ruim.
struct DistributionBars: View {
    @Environment(\.colorScheme) private var scheme
    struct Item: Identifiable {
        let id: String
        let label: String
        let value: Double
        let unitSuffix: String
    }
    let items: [Item]

    private var maxValue: Double { max(items.map(\.value).max() ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.label)
                            .font(.subheadline)
                            .foregroundStyle(Palette.inkSecondary(scheme))
                        Spacer()
                        Text("\(Format.decimal(item.value, 0)) \(item.unitSuffix)")
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(Palette.ink(scheme))
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Palette.surfaceRaised(scheme))
                            Rectangle().fill(Palette.neutral(scheme))
                                .frame(width: geo.size.width
                                       * CGFloat(item.value / maxValue))
                        }
                    }
                    .frame(height: 8)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.label): \(Format.decimal(item.value, 0)) "
                                  + item.unitSuffix)
            }
        }
    }
}
