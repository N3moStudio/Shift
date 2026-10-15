import Foundation
import MapKit

enum RouteContinuation {
    static func make(original: PlannedRoute, from coordinate: CLLocationCoordinate2D,
                     choice: ArrivalChoice, mode: TravelMode, speed: Double,
                     preferWalking: Bool) async throws -> PlannedRoute {
        let first = original.track.point(at: 0)
        let current = RoutePoint(coordinate)
        let start = RoutePlace(name: "Current simulated location", coordinate: coordinate)
        let destination = RoutePlace(name: original.origin.name, coordinate: first.coordinate)
        var connector: PlannedRoute?
        if current.distance(to: first) >= 1 {
            connector = try await RouteBuilder.mapRoutes(from: start, to: destination, mode: mode,
                                                        preferWalkingPaths: preferWalking).first
            guard connector != nil else { throw ContinuationError.noPath }
        }
        try Task.checkCancellation()
        if choice == .returnTrip {
            guard let connector else { throw ContinuationError.alreadyAtStart }
            return connector
        }
        guard choice == .repeatTrip else { throw ContinuationError.noPath }
        var prefix = [current]
        if let connector {
            guard let a = connector.track.points.first, let b = connector.track.points.last,
                  a.distance(to: current) <= 25, b.distance(to: first) <= 25 else { throw ContinuationError.noPath }
            prefix += connector.track.points
        }
        prefix.append(first)
        let offset = RouteTrack(prefix)?.length ?? 0
        guard let track = RouteTrack(prefix + original.track.points) else { throw ContinuationError.noPath }
        var sections: [RouteTravelSection] = []
        if !original.travelSections.isEmpty {
            if offset > 0 { sections.append(RouteTravelSection(id: UUID(), startMetres: 0, endMetres: offset, mode: mode, speedMPH: speed)) }
            sections += original.travelSections.map {
                RouteTravelSection(id: $0.id, startMetres: $0.startMetres + offset, endMetres: $0.endMetres + offset, mode: $0.mode, speedMPH: $0.speedMPH)
            }
            sections[sections.count - 1].endMetres = track.length
            guard RouteTravelSection.valid(sections, length: track.length) else { throw ContinuationError.tooManySections }
        }
        let stops = original.stops.map { RouteStop(id: $0.id, name: $0.name, metres: min(track.length, $0.metres + offset), waitSeconds: $0.waitSeconds) }
        let initialGap = connector?.track.points.first.map { current.distance(to: $0) } ?? 0
        var instructions = (connector?.instructions ?? []).enumerated().map { index, step in
            RouteInstruction(id: index, text: step.text, endDistance: min(offset, step.endDistance + initialGap))
        }
        for step in original.instructions {
            instructions.append(RouteInstruction(id: instructions.count, text: step.text, endDistance: min(track.length, step.endDistance + offset)))
        }
        return PlannedRoute(name: "Repeat \(original.name)", origin: start, destination: original.destination,
            coordinates: track.points.map(\.coordinate), track: track,
            source: connector.map { $0.source == original.source ? original.source : .mixedModes } ?? original.source, distance: track.length,
            notices: (connector?.notices ?? []) + [offset > 0
                ? "First follows new directions to the start, then repeats the saved path. Review the full connecting path before Start route."
                : "Repeats the exact path from its start."],
            appleTravelTime: nil, instructions: instructions, calculatedAt: Date(), stops: stops,
            storedMode: mode, travelSections: sections)
    }
    enum ContinuationError: LocalizedError {
        case noPath, alreadyAtStart, tooManySections
        var errorDescription: String? {
            switch self {
            case .noPath: return "Couldn't find a connected path back to the start. Your location is still held here."
            case .alreadyAtStart: return "You're already at the start of this route. Choose Stay here or Repeat instead."
            case .tooManySections: return "This trip has too many sections to add a connecting route. Plan a return trip first."
            }
        }
    }
}
