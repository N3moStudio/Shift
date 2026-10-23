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
    static let range: ClosedRange<Double> = 0...3600
    static func normalized(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(range.upperBound, max(range.lowerBound, seconds.rounded()))
    }
    static func label(_ seconds: Double) -> String {
        let total = Int(normalized(seconds))
        if total == 0 { return "Pass through" }
        let minutes = total / 60, remainder = total % 60
        if minutes == 0 { return "\(remainder) sec" }
        if remainder == 0 { return "\(minutes) min" }
        return "\(minutes) min \(remainder) sec"
    }
}
