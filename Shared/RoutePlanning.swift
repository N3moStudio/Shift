import Foundation

enum RouteNetwork: String, Codable {
    case walking, cycling, driving

    var title: String {
        switch self {
        case .walking: return "Walking paths"
        case .cycling: return "Cycling route"
        case .driving: return "Driving route"
        }
    }
}

enum TravelMode: String, CaseIterable, Identifiable, Codable {
    case walk, run, cycle, eBike, drive

    var id: String { rawValue }
    var title: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .cycle: return "Cycle"
        case .eBike: return "E-bike"
        case .drive: return "Drive"
        }
    }
    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle, .eBike: return "bicycle"
        case .drive: return "car.fill"
        }
    }
    var routeNetwork: RouteNetwork {
        switch self {
        case .walk, .run: return .walking
        case .cycle, .eBike: return .cycling
        case .drive: return .driving
        }
    }
    var speedRangeMPH: ClosedRange<Double> {
        switch self {
        case .walk: return 1...6
        case .run: return 1...15
        case .cycle, .eBike: return 1...35
        case .drive: return 1...85
        }
    }
    var defaultSpeedMPH: Double { self == .eBike ? EBikeSpeed.defaultMPH : (baseSpeed / 0.44704 * 10).rounded() / 10 }
    func clampedSpeedMPH(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSpeedMPH }
        return min(speedRangeMPH.upperBound, max(speedRangeMPH.lowerBound, value))
    }
    func needsRouteChoice(changingTo other: TravelMode) -> Bool {
        (self == .drive) != (other == .drive)
    }
    /// Metres per second; e-bike playback reads its adjustable speed separately.
    var baseSpeed: Double {
        switch self {
        case .walk: return 1.4
        case .run: return 3.3
        case .cycle: return 6.5
        case .eBike: return EBikeSpeed.metresPerSecond(EBikeSpeed.defaultMPH)
        case .drive: return 13.4
        }
    }
}

enum EBikeSpeed {
    static let range: ClosedRange<Double> = 1...35
    static let defaultMPH: Double = 20
    static let preferenceKey = "locus.eBikeSpeedMPH"

    static func clamped(_ mph: Double) -> Double {
        guard mph.isFinite else { return defaultMPH }
        return min(range.upperBound, max(range.lowerBound, mph))
    }
    static func metresPerSecond(_ mph: Double) -> Double { clamped(mph) * 0.44704 }
}

/// Route provenance remains visible even when the user changes playback speed.
enum RoutePathSource: Equatable, Codable {
    case apple(RouteNetwork), walkingForCycling(fallback: Bool), mixedCyclingWalking, mixedModes, drawn, gpx

    var isAutomatic: Bool {
        switch self {
        case .apple, .walkingForCycling, .mixedCyclingWalking, .mixedModes: return true
        case .drawn, .gpx: return false
        }
    }
    func supports(_ mode: TravelMode) -> Bool {
        if case .apple(let network) = self { return network == mode.routeNetwork }
        if case .walkingForCycling = self { return mode != .drive }
        if self == .mixedCyclingWalking { return mode != .drive }
        if self == .mixedModes { return false }
        return true
    }
    var title: String {
        switch self {
        case .apple(let network): return "Apple Maps · \(network.title)"
        case .walkingForCycling(let fallback): return fallback ? "Walking path · cycling unavailable" : "Walking path · selected"
        case .mixedCyclingWalking: return "Cycling + walking paths"
        case .mixedModes: return "Directions for each travel mode"
        case .drawn: return "Drawn path"
        case .gpx: return "Imported GPX"
        }
    }
    var pathNetwork: RouteNetwork? {
        switch self {
        case .apple(let network): return network
        case .walkingForCycling: return .walking
        case .drawn, .gpx, .mixedCyclingWalking, .mixedModes: return nil
        }
    }
    func playbackNote(mode: TravelMode) -> String? {
        if self == .mixedModes { return "This path includes sections with different travel modes." }
        if self == .mixedCyclingWalking { return "Some legs use walking paths where cycling directions were unavailable." }
        if case .walkingForCycling(let fallback) = self {
            return "\(fallback ? "Cycling unavailable. " : "")Using a walking path at \(mode.title.lowercased()) speed."
        }
        if let network = pathNetwork, network != mode.routeNetwork {
            return "Keeping the \(network.title.lowercased()) at \(mode.title.lowercased()) speed."
        }
        return nil
    }
}

enum RouteMovement {
    /// Bounded steps allow a speed edit to take effect without waiting for a
    /// whole polyline segment. Never advance using time spent suspended.
    static func step(remainingMetres: Double, metresPerSecond: Double) -> (metres: Double, seconds: Double)? {
        guard remainingMetres.isFinite, metresPerSecond.isFinite,
              remainingMetres > 0, metresPerSecond > 0 else { return nil }
        let seconds = min(0.5, remainingMetres / metresPerSecond)
        return (min(remainingMetres, metresPerSecond * seconds), seconds)
    }
}

/// A marker may expire while it is only a preview. An explicit tap accepts the
/// command once; waiting behind another write must not silently expire it.
struct AcceptedRouteSeek: Equatable {
    let routeID: UUID
    let metres: Double

    init?(_ preview: RouteSeek, routeID: UUID?, now: Date) {
        guard preview.isValid(routeID: routeID, now: now) else { return nil }
        self.routeID = preview.routeID
        metres = preview.metres
    }

    func belongs(to routeID: UUID?) -> Bool { self.routeID == routeID }
}

enum RouteRefreshPolicy {
    /// Moving playback already sends locations. A separate heartbeat competes
    /// with Pause/Teleport, so refresh only held positions or stale evidence.
    static func shouldSend(workerActive: Bool, paused: Bool, waitingAtStop: Bool,
                           hasPendingSeek: Bool, phase: SessionPhase) -> Bool {
        switch phase {
        case .idle, .stopping, .disconnected: return false
        case .connecting, .reconnecting, .unverified: return true
        case .active:
            if hasPendingSeek { return false }
            return !workerActive || paused || waitingAtStop
        }
    }

    static func stateAfterPause(paused: Bool, writeInFlight: Bool, waitingAtStop: Bool) -> JourneyState {
        if paused { return writeInFlight ? .pausing : .paused }
        return waitingAtStop ? .waiting : .moving
    }
}

enum JourneyState: String, Codable, Hashable {
    case moving, waiting, pausing, paused, stopping, seeking, arrived, interrupted
    var title: String {
        switch self {
        case .moving: return "Following route"
        case .waiting: return "Waiting at stop"
        case .pausing: return "Pausing…"
        case .paused: return "Route paused"
        case .stopping: return "Stopping route…"
        case .seeking: return "Moving to selected point…"
        case .arrived: return "Arrived"
        case .interrupted: return "Journey interrupted"
        }
    }
}

/// Opening the joystick is a UI action, never permission to start a session.
enum JoystickAccess: Equatable {
    case ready, notStarted, needsConnection, routeInProgress, busy

    static func check(sessionRequested: Bool, hasLocation: Bool, phase: SessionPhase,
                      hasRoute: Bool, isBusy: Bool) -> JoystickAccess {
        if isBusy { return .busy }
        guard sessionRequested, hasLocation else { return .notStarted }
        guard phase == .active else { return .needsConnection }
        guard !hasRoute else { return .routeInProgress }
        return .ready
    }

    var message: String? {
        switch self {
        case .ready: return nil
        case .notStarted: return "Location hasn't been spoofed yet."
        case .needsConnection: return "Reconnect before using the joystick."
        case .routeInProgress: return "Stop the route before using the joystick."
        case .busy: return "Wait for the current location update to finish."
        }
    }
}

struct RouteInstruction: Identifiable, Codable, Equatable {
    let id: Int
    let text: String
    let endDistance: Double
}

struct JourneyProgress: Equatable {
    let totalMetres: Double
    private(set) var travelledMetres: Double = 0
    var state: JourneyState = .moving

    var remainingMetres: Double { max(0, totalMetres - travelledMetres) }
    var fraction: Double { totalMetres > 0 ? min(1, max(0, travelledMetres / totalMetres)) : 0 }

    mutating func confirmMovement(_ metres: Double) {
        guard metres.isFinite, metres >= 0, totalMetres.isFinite else { return }
        travelledMetres = min(totalMetres, travelledMetres + metres)
    }

    /// Called only after a seek command succeeds; backwards jumps are explicit.
    mutating func confirmPosition(_ metres: Double) {
        guard metres.isFinite, totalMetres.isFinite else { return }
        travelledMetres = min(totalMetres, max(0, metres))
    }

    func remainingSeconds(speed: Double, fresh: Bool) -> TimeInterval? {
        guard state == .moving, fresh, speed.isFinite, speed > 0 else { return nil }
        return remainingMetres / speed
    }

    func instructionIndex(in steps: [RouteInstruction]) -> Int? {
        guard !steps.isEmpty else { return nil }
        return steps.firstIndex { $0.endDistance > travelledMetres + 0.5 } ?? steps.indices.last
    }
}

struct JourneyActivity: Codable, Hashable {
    let state: JourneyState
    let progress: Double
    let remainingMetres: Double
    let estimatedArrival: Date?
}

enum JourneyText {
    static func distance(_ metres: Double) -> String {
        guard metres.isFinite, metres >= 0 else { return "—" }
        return metres < 160.9344 ? String(format: "%.0f ft", metres * 3.28084) : String(format: "%.1f mi", metres / 1609.344)
    }
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let minutes = max(1, Int(min(seconds / 60, 525600).rounded(.up)))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr \(minutes % 60) min"
    }
}
