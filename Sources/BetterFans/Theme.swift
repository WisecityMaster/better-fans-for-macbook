import SwiftUI
import FanCore

/// Shared look: one temperature colour scale and a few small building blocks used across windows.
enum Theme {
    static let cpu = Color(red: 0.96, green: 0.45, blue: 0.20)
    static let gpu = Color(red: 0.30, green: 0.55, blue: 0.98)
    static let fanColors: [Color] = [Color(red: 0.20, green: 0.72, blue: 0.62), Color(red: 0.62, green: 0.44, blue: 0.92)]

    static func fan(_ i: Int) -> Color { fanColors[i % fanColors.count] }

    /// Same thresholds everywhere: calm < 60, warm < 80, hot < 90, critical above.
    static func temp(_ t: Double?) -> Color {
        guard let t else { return .secondary }
        switch t {
        case ..<60: return .green
        case ..<80: return .yellow
        case ..<90: return .orange
        default:    return .red
        }
    }

    static func celsius(_ t: Double?, decimals: Int = 0) -> String {
        guard let t else { return "–" }
        return String(format: "%.\(decimals)f °C", t)
    }

    static func rpm(_ v: Double) -> String { "\(Int(v.rounded()).formatted()) rpm" }

    static func icon(for p: Profile) -> String {
        switch p.mode {
        case .auto:  return "apple.logo"
        case .fixed: return "gauge.high"
        case .curve: return "chart.xyaxis.line"
        }
    }

    static let card = Color.primary.opacity(0.05)
}

/// Rounded tinted label: helper/curve state at a glance.
struct StatusPill: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

extension AppModel {
    /// One place that decides what the status pill says.
    var status: (text: String, icon: String, tint: Color, detail: String?) {
        if !helperReachable {
            return ("Helper detenido", "bolt.slash.fill", .secondary, "macOS controla los ventiladores. Instala el helper con scripts/install-helper.sh.")
        }
        if let err = helperStatus?.lastError {
            return ("Error", "exclamationmark.triangle.fill", .red, err)
        }
        if helperStatus?.controlling == true {
            if let t = temperature, t >= FanController.hardLimitC {
                return ("Límite térmico", "flame.fill", .red, "≥ \(Int(FanController.hardLimitC)) °C: ventiladores al máximo.")
            }
            return (selected.isCurve ? "Curva activa" : "Velocidad fija", "fanblades.fill", .green, nil)
        }
        return ("Control de Apple", "apple.logo", .secondary, nil)
    }
}

/// Fan speed as a bar between its hardware min and max.
struct FanBar: View {
    let fan: FanReading

    private var fraction: Double {
        guard fan.maxRPM > fan.minRPM else { return 0 }
        return min(1, max(0, (fan.actualRPM - fan.minRPM) / (fan.maxRPM - fan.minRPM)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Ventilador \(fan.index + 1)", systemImage: "fanblades")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Theme.rpm(fan.actualRPM)).font(.caption.weight(.medium)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Theme.fan(fan.index).gradient)
                        .frame(width: max(6, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
        .help("Mín. \(Theme.rpm(fan.minRPM)) · máx. \(Theme.rpm(fan.maxRPM)) · objetivo \(Theme.rpm(fan.targetRPM))")
    }
}

/// Small labelled number used in the monitor header.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }
}
