import Foundation

enum ArrivalChoice: String, Codable, CaseIterable, Identifiable {
    case stay, returnTrip, repeatTrip
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stay: return "Stay here"
        case .returnTrip: return "Plan a return trip"
        case .repeatTrip: return "Repeat this route"
        }
    }
    var actionTitle: String { self == .returnTrip ? "Preview return trip" : "Preview repeat trip" }
}

/// A checkpoint is evidence of a saved command, never a live connection.
struct TripCheckpoint: Codable, Equatable {
    var version = 1
    var trip: SavedTrip
    var metres: Double
    var stops: RouteStopProgress
    var confirmedAt: Date
    var savedAt: Date
    var arrival: ArrivalChoice

    var isValid: Bool {
        guard version == 1, trip.isValid, let track = RouteTrack(trip.points),
              metres.isFinite, (0...track.length).contains(metres),
              confirmedAt.timeIntervalSince1970.isFinite, savedAt.timeIntervalSince1970.isFinite,
              confirmedAt <= savedAt else { return false }
        return stops.isValid(for: trip.stops, at: metres)
    }
}

enum PanelShortcut: String, Codable, CaseIterable, Identifiable {
    case saved, joystick, settings, speed, pause
    case batterySaver // Decode old backups only; never offered as a control.
    static let allCases: [Self] = [.saved, .joystick, .settings, .speed, .pause]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .saved: return "Saved"
        case .joystick: return "Joystick"
        case .settings: return "Settings"
        case .speed: return "Speed"
        case .pause: return "Pause / Continue"
        case .batterySaver: return "Battery Saver"
        }
    }
    var icon: String {
        switch self {
        case .saved: return "star"
        case .joystick: return "gamecontroller"
        case .settings: return "gearshape"
        case .speed: return "speedometer"
        case .pause: return "pause.fill"
        case .batterySaver: return "battery.25percent"
        }
    }
    static let defaults: [Self] = [.saved, .joystick, .settings]
    static func normalized(_ values: [Self]) -> [Self] {
        var result: [Self] = []
        for value in values where value != .batterySaver && !result.contains(value) { result.append(value) }
        return result.isEmpty ? defaults : Array(result.prefix(3))
    }
}
