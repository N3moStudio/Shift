import Foundation

/// Saved trips retain MPH for compatibility; route geometry and playback use SI.
/// Convert only at the UI boundary, never round the stored or playback speed.
enum SpeedUnit: String, Codable, CaseIterable, Identifiable {
    case mph, kilometersPerHour

    var id: String { rawValue }
    var symbol: String { self == .mph ? "mph" : "km/h" }
    var title: String { self == .mph ? "Miles per hour (mph)" : "Kilometers per hour (km/h)" }
    var spokenName: String { self == .mph ? "miles per hour" : "kilometers per hour" }
    var alternate: Self { self == .mph ? .kilometersPerHour : .mph }

    func value(fromMPH mph: Double) -> Double { self == .mph ? mph : mph * 1.609344 }
    func mph(from value: Double) -> Double { self == .mph ? value : value / 1.609344 }
    /// Snap user edits to the selected unit's scale, not to a converted MPH grid.
    func selectedMPH(_ value: Double, mode: TravelMode) -> Double {
        guard value.isFinite else { return mode.defaultSpeedMPH }
        let step = mode == .walk || mode == .run ? 0.1 : 1.0
        return mode.clampedSpeedMPH(mph(from: (value / step).rounded() * step))
    }
    func range(for mode: TravelMode) -> ClosedRange<Double> {
        value(fromMPH: mode.speedRangeMPH.lowerBound)...value(fromMPH: mode.speedRangeMPH.upperBound)
    }
    func formatted(mph: Double) -> String {
        "\(value(fromMPH: mph).formatted(.number.precision(.fractionLength(1)))) \(symbol)"
    }
    func rangeLabel(for mode: TravelMode) -> String {
        let bounds = range(for: mode)
        return "\(bounds.lowerBound.formatted(.number.precision(.fractionLength(1))))–\(bounds.upperBound.formatted(.number.precision(.fractionLength(1)))) \(symbol)"
    }
}

enum SpeedConversion {
    static func metresPerSecond(mph: Double) -> Double { mph * 0.44704 }
    static func mph(metresPerSecond: Double) -> Double { metresPerSecond / 0.44704 }
}

enum StopDuration {
    static let range: ClosedRange<Double> = 0...86_400
    enum Component: CaseIterable {
        case hours, minutes, seconds
        var title: String {
            switch self {
            case .hours: return "Hours"
            case .minutes: return "Minutes"
            case .seconds: return "Seconds"
            }
        }
        var maximum: Int { self == .hours ? 24 : 59 }
        var multiplier: Int {
            switch self {
            case .hours: return 3600
            case .minutes: return 60
            case .seconds: return 1
            }
        }
    }
    static func isValid(_ seconds: Double) -> Bool { seconds.isFinite && range.contains(seconds) }
    static func normalized(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(range.upperBound, max(range.lowerBound, seconds.rounded()))
    }
    static func value(_ component: Component, in seconds: Double) -> Int {
        let total = Int(normalized(seconds))
        return component == .hours ? total / 3600 : (total / component.multiplier) % 60
    }
    static func replacing(_ component: Component, in seconds: Double, with value: Int) -> Double {
        let total = Int(normalized(seconds))
        let previous = self.value(component, in: seconds)
        let next = min(component.maximum, max(0, value))
        return normalized(Double(total + (next - previous) * component.multiplier))
    }
    static func label(_ seconds: Double) -> String {
        let total = Int(normalized(seconds))
        if total == 0 { return "Pass through" }
        return formatted(Double(total))
    }
    /// Aggregate route waits may exceed the per-stop limit; do not clamp display totals.
    static func formatted(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, remainder = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hr") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if remainder > 0 || parts.isEmpty { parts.append("\(remainder) sec") }
        return parts.joined(separator: " ")
    }
}
