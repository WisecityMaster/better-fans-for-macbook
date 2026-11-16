import SwiftUI
import Charts
import FanCore

/// CPU and GPU over time. `compact` is the menu sparkline: no axes, no legend, no hover.
struct TemperatureChart: View {
    let samples: [HistorySample]
    var hover: HistorySample? = nil
    var compact = false
    var xDomain: ClosedRange<Date>? = nil
    var onHover: ((Date?) -> Void)? = nil

    /// With "Differentiate without color" the GPU line is dashed, not just blue.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var noColor

    var body: some View {
        let domain = temperatureDomain(samples)
        Chart {
            ForEach(samples) { s in
                if let cpu = s.cpu {
                    AreaMark(x: .value("Hora", s.time), yStart: .value("Base", domain.lowerBound), yEnd: .value("°C", cpu))
                        .foregroundStyle(.linearGradient(colors: [Theme.cpu.opacity(compact ? 0.35 : 0.25), Theme.cpu.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Hora", s.time), y: .value("°C", cpu), series: .value("Sensor", "CPU"))
                        .foregroundStyle(by: .value("Sensor", "CPU"))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: compact ? 1.5 : 2))
                }
                if !compact, let gpu = s.gpu {
                    LineMark(x: .value("Hora", s.time), y: .value("°C", gpu), series: .value("Sensor", "GPU"))
                        .foregroundStyle(by: .value("Sensor", "GPU"))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: noColor ? [6, 3] : []))
                }
            }
            if !compact, domain.contains(FanController.hardLimitC) {
                RuleMark(y: .value("Límite", FanController.hardLimitC))
                    .foregroundStyle(.red.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Límite térmico \(Int(FanController.hardLimitC)) °C").font(.caption).foregroundStyle(.red)
                    }
            }
            if let h = hover {
                RuleMark(x: .value("Hora", h.time)).foregroundStyle(Color.secondary.opacity(0.5))
                if let cpu = h.cpu { PointMark(x: .value("Hora", h.time), y: .value("°C", cpu)).foregroundStyle(Theme.cpu) }
                if let gpu = h.gpu { PointMark(x: .value("Hora", h.time), y: .value("°C", gpu)).foregroundStyle(Theme.gpu) }
            }
        }
        .chartForegroundStyleScale(["CPU": Theme.cpu, "GPU": Theme.gpu])
        .chartYScale(domain: domain)
        .chartXScale(domain: timeDomain(samples, xDomain))
        .chartLegend(compact ? .hidden : .visible)
        .chartXAxis { if !compact { timeAxis } }
        .chartYAxis {
            if !compact {
                AxisMarks(position: .leading, values: .stride(by: 10)) { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))°") } }
                }
            }
        }
        .chartOverlay { proxy in
            if let onHover { ChartHoverLayer(proxy: proxy, onHover: onHover) }
        }
        .accessibilityHidden(compact)  // the sparkline's card already describes it
    }
}
