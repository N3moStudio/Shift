import Foundation

enum MovementDefaults {
    static let smoothKey = "locus.smoothMovement"
    static let migrationKey = "locus.smoothDefaultOff.v1"

    static func loadSmoothMovement(from defaults: UserDefaults) -> Bool {
        // Apply the requested new default once to upgrades as well as installs.
        // Later explicit choices, including a saved trip's setting, are retained.
        if !defaults.bool(forKey: migrationKey) {
            defaults.set(false, forKey: smoothKey)
            defaults.set(true, forKey: migrationKey)
        }
        return defaults.bool(forKey: smoothKey)
    }
}

struct TripWaypoint: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var point: RoutePoint
    var waitSeconds: Double = 60
}

struct RouteStop: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var metres: Double
    var waitSeconds: Double

    func isValid(length: Double) -> Bool {
        metres.isFinite && metres >= 0 && metres <= length && StopDuration.isValid(waitSeconds)
    }
}

/// Countdown advances only while the route worker is awake, fresh, and unpaused.
/// A resume after suspension must never silently consume the whole stop.
struct RouteStopProgress: Equatable, Codable {
    private(set) var completed: Set<UUID> = []
    private(set) var currentID: UUID?
    private(set) var remainingSeconds: Double = 0

    func isValid(for stops: [RouteStop], at metres: Double) -> Bool {
        let ids = Set(stops.map(\.id))
        guard completed.isSubset(of: ids), remainingSeconds.isFinite, remainingSeconds >= 0,
              stops.filter({ completed.contains($0.id) }).allSatisfy({ $0.metres <= metres + 0.05 }) else { return false }
        if let currentID {
            guard !completed.contains(currentID), let stop = stops.first(where: { $0.id == currentID }) else { return false }
            return abs(stop.metres - metres) <= 0.05 && remainingSeconds <= stop.waitSeconds
        }
        return remainingSeconds == 0
    }

    func next(in stops: [RouteStop]) -> RouteStop? { stops.first { !completed.contains($0.id) } }
    mutating func arrive(_ stop: RouteStop) {
        guard currentID != stop.id, !completed.contains(stop.id) else { return }
        currentID = stop.id
        remainingSeconds = stop.waitSeconds
        if remainingSeconds <= 0 { finish() }
    }
    mutating func tick(_ seconds: Double) {
        guard currentID != nil, seconds.isFinite, seconds > 0 else { return }
        remainingSeconds = max(0, remainingSeconds - min(0.5, seconds))
        if remainingSeconds <= 0 { finish() }
    }
    mutating func finish() {
        if let currentID { completed.insert(currentID) }
        currentID = nil
        remainingSeconds = 0
    }
    mutating func seek(to metres: Double, stops: [RouteStop]) {
        completed = Set(stops.filter { $0.metres < metres - 0.01 }.map(\.id))
        currentID = nil
        remainingSeconds = 0
    }
    func remainingWait(in stops: [RouteStop]) -> Double {
        stops.filter { !completed.contains($0.id) }.reduce(0) {
            $0 + ($1.id == currentID ? remainingSeconds : $1.waitSeconds)
        }
    }
}

struct RouteJumpUndo: Equatable {
    static let duration: TimeInterval = 10
    let routeID: UUID
    let metres: Double
    let wasPaused: Bool
    let stops: RouteStopProgress
    let expiresAt: Date

    func isValid(routeID current: UUID?, now: Date) -> Bool {
        routeID == current && metres.isFinite && metres >= 0 && now < expiresAt
    }
}

struct RouteMotion {
    struct Turn {
        let metres: Double
        let fraction: Double
    }
    let turns: [Turn]

    init(track: RouteTrack) {
        // Look across several sampled points, not GPS-size polyline noise.
        var result: [Turn] = []
        var distance = 10.0
        while distance < track.length - 10 {
            let a = track.point(at: distance - 10), b = track.point(at: distance), c = track.point(at: distance + 10)
            let scale = max(0.000001, cos(b.latitude * .pi / 180))
            let ax = RoutePoint.longitudeDelta(b.longitude - a.longitude) * scale, ay = b.latitude - a.latitude
            let bx = RoutePoint.longitudeDelta(c.longitude - b.longitude) * scale, by = c.latitude - b.latitude
            let denominator = hypot(ax, ay) * hypot(bx, by)
            if denominator > 0 {
                let angle = acos(min(1, max(-1, (ax * bx + ay * by) / denominator)))
                if angle > .pi / 7 { result.append(Turn(metres: distance, fraction: max(0.15, 1 - angle / .pi * 0.85))) }
            }
            distance += max(10, track.length / 20_000)
        }
        turns = result
    }

    func target(cruise: Double, position: Double, stopAt: Double, mode: TravelMode) -> Double {
        let braking = Self.braking(for: mode)
        var target = min(cruise, sqrt(max(0, 2 * braking * (stopAt - position))))
        let lookAhead = max(25, cruise * cruise / (2 * braking) + 10)
        var low = 0, high = turns.count
        while low < high {
            let mid = (low + high) / 2
            if turns[mid].metres < position - 10 { low = mid + 1 } else { high = mid }
        }
        for turn in turns.dropFirst(low) {
            if turn.metres > position + lookAhead { break }
            let cornerSpeed = cruise * turn.fraction
            let allowance = sqrt(cornerSpeed * cornerSpeed + 2 * braking * max(0, turn.metres - position - 10))
            target = min(target, allowance)
        }
        return target
    }

    static func braking(for mode: TravelMode) -> Double { mode == .drive ? 3 : mode == .walk ? 1 : 1.8 }
    static func step(speed: Double, target: Double, remaining: Double, mode: TravelMode,
                     smooth: Bool, seconds: Double = 0.5) -> (speed: Double, metres: Double) {
        guard speed.isFinite, target.isFinite, remaining.isFinite, seconds.isFinite,
              speed >= 0, target >= 0, remaining > 0, seconds > 0 else { return (0, 0) }
        // Ordinary command latency counts toward travel time. A long sleep or
        // stalled connection gets only one normal step, never a catch-up leap.
        let dt = RoutePlaybackClock.travelTime(for: seconds)
        let acceleration = mode == .drive ? 2.2 : mode == .walk ? 0.8 : 1.3
        let next = smooth ? (target >= speed ? min(target, speed + acceleration * dt) : max(target, speed - braking(for: mode) * dt)) : target
        let movement = smooth ? (speed + next) * 0.5 * dt : next * dt
        let metres = min(remaining, max(0, movement))
        return (metres >= remaining ? 0 : next, metres)
    }
}

struct RoutePlaybackClock {
    static let interval = 0.5
    static let maximumGap = 1.5
    private(set) var lastDispatch: Double

    init(now: Double) { lastDispatch = now }
    mutating func reset(now: Double) { lastDispatch = now }
    func delay(now: Double) -> Double { max(0, Self.interval - max(0, now - lastDispatch)) }
    mutating func advance(now: Double) -> Double {
        let elapsed = now - lastDispatch
        lastDispatch = now
        return Self.travelTime(for: elapsed)
    }
    static func travelTime(for elapsed: Double) -> Double {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        return elapsed > maximumGap ? interval : elapsed
    }
}

struct RouteSpeedSamples {
    private var values: [(metres: Double, seconds: Double)] = []
    var metresPerSecond: Double {
        let time = values.reduce(0) { $0 + $1.seconds }
        return time > 0 ? values.reduce(0) { $0 + $1.metres } / time : 0
    }
    mutating func append(metres: Double, seconds: Double) {
        guard metres.isFinite, seconds.isFinite, metres >= 0, seconds > 0 else { return }
        values.append((metres, seconds))
        if values.count > 5 { values.removeFirst() }
    }
    mutating func reset() { values.removeAll(keepingCapacity: true) }
}

struct SavedTrip: Identifiable, Codable, Equatable {
    var version = 1
    var id = UUID()
    var name: String
    var mode: TravelMode
    var speedMPH: Double
    var smoothMovement: Bool
    var originName: String
    var destinationName: String
    var points: [RoutePoint]
    var source: RoutePathSource
    var instructions: [RouteInstruction]
    var stops: [RouteStop]
    var calculatedAt: Date
    var savedAt = Date()
    var travelSections: [RouteTravelSection]? = nil
    var folder: String? = nil
    var arrival: ArrivalChoice? = nil

    func duplicated(existingNames: Set<String>, now: Date = Date()) -> Self {
        var copy = self
        copy.id = UUID()
        copy.savedAt = now
        let base = String(name.prefix(100))
        let used = Set(existingNames.map { $0.lowercased() })
        var title = base + " (copy)"
        var number = 2
        while used.contains(title.lowercased()) {
            title = base + " (copy \(number))"
            number += 1
        }
        copy.name = title
        return copy
    }

    var isValid: Bool {
        guard version == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 120, (folder.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 60 } ?? true),
              points.count <= 100_000, let track = RouteTrack(points),
              speedMPH.isFinite, mode.speedRangeMPH.contains(speedMPH), stops.count <= 20,
              Set(stops.map(\.id)).count == stops.count,
              stops.allSatisfy({ $0.isValid(length: track.length) }),
              zip(stops, stops.dropFirst()).allSatisfy({ pair in pair.0.metres <= pair.1.metres }),
              Set(instructions.map(\.id)).count == instructions.count,
              instructions.allSatisfy({ $0.endDistance.isFinite && $0.endDistance >= 0 && $0.endDistance <= track.length + 1 }) else { return false }
        if let travelSections, !RouteTravelSection.valid(travelSections, length: track.length) { return false }
        return true
    }
}
