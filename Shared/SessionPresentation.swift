import Foundation

/// A visible map may use foreground location. Only a confirmed, still-running
/// session owns the background keep-alive; changing tabs must not release it.
enum LocationTrackingDemand: Equatable {
    case stopped, map, session

    static func resolve(appActive: Bool, mapVisible: Bool, sessionKeepsAlive: Bool) -> Self {
        if sessionKeepsAlive { return .session }
        return appActive && mapVisible ? .map : .stopped
    }
}

/// Shared by the app and its Live Activity. A successful command is evidence of
/// the developer session only; it cannot verify what Find My or Life360 displays.
enum SessionPhase: String, Codable, Hashable {
    case idle, connecting, active, reconnecting, stopping, unverified, disconnected

    var title: String {
        switch self {
        case .idle: return "No active session"
        case .connecting: return "Connecting"
        case .active: return "Location update sent"
        case .reconnecting: return "Checking connection"
        case .stopping: return "Stopping session"
        case .unverified: return "Status unverified"
        case .disconnected: return "Location update failed"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "location.circle"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .active: return "paperplane.fill"
        case .stopping: return "stop.circle"
        case .unverified: return "questionmark.circle.fill"
        case .disconnected: return "exclamationmark.triangle.fill"
        }
    }

    func presented(isStale: Bool) -> SessionPhase {
        guard isStale else { return self }
        switch self {
        case .active, .connecting, .reconnecting, .stopping: return .unverified
        default: return self
        }
    }
}

enum SessionTiming {
    static let refreshInterval: TimeInterval = 5
    static let evidenceLifetime: TimeInterval = 12
    static let operationDeadline: TimeInterval = 12
    static let defaultCheckSeconds = 10
    static func checkSeconds(_ value: Int) -> Int { min(15, max(3, value)) }
    static func evidenceLifetime(checkSeconds: Int) -> TimeInterval {
        TimeInterval(Self.checkSeconds(checkSeconds)) + 7
    }

    /// A held location uses the selected refresh cadence, without one-second polling.
    /// Wake sooner for command/evidence deadlines or a due helper check.
    static func monitorDelay(now: Date, fast: Bool, refreshAt: Date?, evidenceAt: Date?,
                             operationAt: Date?, helperAt: Date?, interval: TimeInterval = refreshInterval) -> TimeInterval {
        let ceiling: TimeInterval = fast ? 1 : interval
        if let refreshAt, refreshAt <= now { return 0.01 }
        let future = [refreshAt, evidenceAt, operationAt, helperAt].compactMap { $0 }
            .map { $0.timeIntervalSince(now) }.filter { $0 > 0 }
        return max(0.01, min(ceiling, future.min() ?? ceiling))
    }

    static func isFresh(_ date: Date?, now: Date = Date(), lifetime: TimeInterval = evidenceLifetime) -> Bool {
        guard let date else { return false }
        let age = now.timeIntervalSince(date)
        return age >= 0 && age < lifetime
    }
}

struct SessionSnapshot: Codable, Hashable {
    var phase: SessionPhase
    var startedAt: Date
    var lastConfirmedAt: Date?
    var expiresAt: Date?
    var place: String?
    var lowPower: Bool
    var journey: JourneyActivity? = nil
    // Optional fields allow an extension to decode activities from older builds.
    var islandPlace: String? = nil
    var lockScreenShowsProgress: Bool? = nil
    var islandShowsProgress: Bool? = nil
    var islandShowsTimer: Bool? = nil
    var remoteFindMy: RemoteFindMyActivity? = nil
    var connectionCheckSeconds: Int? = nil
    var visualStyle: String? = nil
    var iconDesign: String? = nil

    func visibleJourney(onIsland: Bool, at now: Date, systemIsStale: Bool = false) -> JourneyActivity? {
        let enabled = onIsland ? islandShowsProgress : lockScreenShowsProgress
        return enabled == false ? nil : presentedJourney(at: now, systemIsStale: systemIsStale)
    }

    func presentedPhase(at now: Date, systemIsStale: Bool = false) -> SessionPhase {
        let lifetime = connectionCheckSeconds.map { SessionTiming.evidenceLifetime(checkSeconds: $0) } ?? SessionTiming.evidenceLifetime
        let evidenceMissing = phase == .active && !SessionTiming.isFresh(lastConfirmedAt, now: now, lifetime: lifetime)
        return phase.presented(isStale: evidenceMissing || systemIsStale || expiresAt.map { now >= $0 } == true)
    }

    func presentedJourney(at now: Date, systemIsStale: Bool = false) -> JourneyActivity? {
        presentedPhase(at: now, systemIsStale: systemIsStale) == .active ? journey : nil
    }

    var explanation: String {
        switch phase {
        case .idle: return "Choose a place on the map."
        case .connecting: return "Opening the developer connection."
        case .active: return "Your phone accepted the last update. Check other apps separately."
        case .reconnecting: return "Waiting for a fresh location update."
        case .stopping: return "Waiting for iOS to clear the simulation."
        case .unverified: return "Open Shift to check. Location may still be simulated."
        case .disconnected: return "Simulation may remain. Open Shift to retry or stop."
        }
    }
}

/// A user label belongs to one confirmed spot, never to the moving dot forever.
/// This value is deliberately not persisted in preferences, recents, or trips.
struct SessionSpotName: Equatable {
    static let nearbyMetres = 5.0
    let name: String
    let point: RoutePoint

    init?(_ text: String, at point: RoutePoint) {
        let clean = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard point.isValid, !clean.isEmpty else { return nil }
        name = String(clean.prefix(60))
        self.point = point
    }

    func display(at current: RoutePoint) -> String? {
        guard current.isValid else { return nil }
        return point.distance(to: current) <= Self.nearbyMetres ? name : nil
    }
}
