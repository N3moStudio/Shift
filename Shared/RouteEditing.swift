import Foundation

/// A choice belongs to the place being travelled to, so reordering stops keeps
/// their incoming choices. No choices exist until Advanced is explicitly enabled.
struct RouteLegChoice: Codable, Equatable {
    var mode: TravelMode
    var speedMPH: Double
    var isValid: Bool { speedMPH.isFinite && mode.speedRangeMPH.contains(speedMPH) }
    static let destinationID = UUID(uuidString: "A6000000-0000-0000-0000-000000000001")!
}

struct RouteTravelSection: Identifiable, Codable, Equatable {
    var id: UUID
    var startMetres: Double
    var endMetres: Double
    var mode: TravelMode
    var speedMPH: Double
    var metresPerSecond: Double { mode.clampedSpeedMPH(speedMPH) * 0.44704 }

    static func valid(_ sections: [Self], length: Double) -> Bool {
        guard !sections.isEmpty, sections.count <= 21, length.isFinite, length > 0,
              Set(sections.map(\.id)).count == sections.count else { return false }
        var cursor = 0.0
        for section in sections {
            guard section.startMetres.isFinite, section.endMetres.isFinite,
                  abs(section.startMetres - cursor) <= 0.05, section.endMetres > section.startMetres,
                  section.endMetres <= length + 0.05,
                  RouteLegChoice(mode: section.mode, speedMPH: section.speedMPH).isValid else { return false }
            cursor = section.endMetres
        }
        return abs(cursor - length) <= 0.05
    }
    static func current(in sections: [Self], at metres: Double) -> Self? {
        guard metres.isFinite else { return nil }
        return sections.first { metres < $0.endMetres - 0.001 } ?? sections.last
    }
    static func remainingSeconds(_ sections: [Self], from metres: Double,
                                 overrides: [UUID: Double] = [:]) -> Double {
        sections.reduce(0) { total, section in
            let remaining = max(0, section.endMetres - max(section.startMetres, metres))
            let speed = section.mode.clampedSpeedMPH(overrides[section.id] ?? section.speedMPH) * 0.44704
            return total + remaining / speed
        }
    }
}

/// UI-only rehearsal. It has no device engine, connection, or session dependency.
/// Explicit time steps make pausing/background behavior independent of wall time.
struct RouteRehearsal {
    private(set) var metres = 0.0
    private(set) var waitingSeconds = 0.0
    private(set) var completedStops: Set<UUID> = []
    private(set) var waitingID: UUID?
    var isPlaying = false
    var rate = 10.0

    mutating func reset() { self = RouteRehearsal() }
    mutating func skipWait() {
        if let waitingID { completedStops.insert(waitingID) }
        waitingID = nil
        waitingSeconds = 0
    }
    mutating func advance(seconds: Double, length: Double, speed: Double,
                          sections: [RouteTravelSection], stops: [RouteStop]) {
        guard isPlaying, seconds.isFinite, seconds > 0, length.isFinite, length > 0,
              speed.isFinite, speed > 0, rate.isFinite else { return }
        // Never fast-forward through time spent backgrounded or suspended.
        var remainingTime = min(0.25, seconds) * min(100, max(1, rate))
        for _ in 0..<64 {
            if let waitingID {
                let consumed = min(waitingSeconds, remainingTime)
                waitingSeconds -= consumed
                remainingTime -= consumed
                if waitingSeconds <= 0 {
                    completedStops.insert(waitingID)
                    self.waitingID = nil
                } else { return }
            }
            if let stop = stops.first(where: { !completedStops.contains($0.id) }), stop.metres <= metres + 0.001 {
                waitingID = stop.id
                waitingSeconds = stop.waitSeconds
                continue
            }
            if metres >= length - 0.001 { metres = length; isPlaying = false; return }
            guard remainingTime > 0 else { return }
            let section = RouteTravelSection.current(in: sections, at: metres)
            let boundary = min(length, stops.first(where: { !completedStops.contains($0.id) })?.metres ?? length,
                               section?.endMetres ?? length)
            let velocity = section?.metresPerSecond ?? speed
            let movement = min(boundary - metres, remainingTime * velocity)
            guard movement > 0 else { return }
            metres += movement
            remainingTime -= movement / velocity
        }
    }
}
