import CoreLocation
import Foundation
import MapKit

struct RoutePlace {
    let name: String
    let coordinate: CLLocationCoordinate2D
    init(name: String, coordinate: CLLocationCoordinate2D) {
        self.name = String(PlaceLabel.readable(name, fallback: "Selected place").prefix(120))
        self.coordinate = coordinate
    }
}

struct PlannedRoute: Identifiable {
    let id = UUID()
    let name: String
    var origin: RoutePlace
    var destination: RoutePlace
    let coordinates: [CLLocationCoordinate2D]
    let track: RouteTrack
    let source: RoutePathSource
    let distance: CLLocationDistance
    let notices: [String]
    let appleTravelTime: TimeInterval?
    let instructions: [RouteInstruction]
    let calculatedAt: Date
    var stops: [RouteStop] = []
    var storedMode: TravelMode? = nil
    var travelSections: [RouteTravelSection] = []

    func supports(_ mode: TravelMode) -> Bool {
        if !travelSections.isEmpty { return RouteTravelSection.valid(travelSections, length: track.length) }
        return source.supports(mode) || storedMode == mode
    }
    func estimate(speed: Double) -> Double {
        let moving = travelSections.isEmpty ? distance / max(0.1, speed) : RouteTravelSection.remainingSeconds(travelSections, from: 0)
        return moving + stops.reduce(0) { $0 + $1.waitSeconds }
    }
}

enum RouteBuilder {
    /// Request each leg in order. Never replace a failed leg with a straight line.
    static func itinerary(from start: RoutePlace, to end: RoutePlace, via stops: [TripWaypoint],
                          mode: TravelMode, preferWalkingPaths: Bool, legChoices: [UUID: RouteLegChoice] = [:],
                          defaultSpeedMPH: Double? = nil) async throws -> [PlannedRoute] {
        if stops.isEmpty && legChoices.isEmpty { return try await mapRoutes(from: start, to: end, mode: mode, preferWalkingPaths: preferWalkingPaths) }
        var legs: [PlannedRoute?] = []
        var origin = start
        let destinations = stops.map({ RoutePlace(name: $0.name, coordinate: $0.point.coordinate) }) + [end]
        let ids = stops.map(\.id) + [RouteLegChoice.destinationID]
        for (index, destination) in destinations.enumerated() {
            try Task.checkCancellation()
            if RoutePoint(origin.coordinate).distance(to: RoutePoint(destination.coordinate)) < 1 {
                legs.append(nil)
                origin = destination
                continue
            }
            let choice = legChoices[ids[index]]
            let choices = try await mapRoutes(from: origin, to: destination, mode: choice?.mode ?? mode, preferWalkingPaths: preferWalkingPaths)
            guard let leg = choices.first else { throw MissingRoute() }
            legs.append(leg)
            origin = destination
        }
        var points: [CLLocationCoordinate2D] = [], pauses: [RouteStop] = [], instructions: [RouteInstruction] = []
        var distance = 0.0
        var sections: [RouteTravelSection] = []
        var hasConnector = false
        for (index, candidate) in legs.enumerated() {
            guard let leg = candidate else {
                if index < stops.count {
                    pauses.append(RouteStop(id: stops[index].id, name: stops[index].name, metres: distance, waitSeconds: stops[index].waitSeconds))
                }
                continue
            }
            let sectionStart = distance
            if let last = points.last, let first = leg.coordinates.first {
                let gap = RoutePoint(last).distance(to: RoutePoint(first))
                guard gap <= 25 else {
                    throw NSError(domain: "Locus", code: 5, userInfo: [NSLocalizedDescriptionKey: "Directions do not join at \(stops[index - 1].name). Move that stop closer to the path and try again."])
                }
                distance += gap >= 0.001 ? gap : 0
                if gap > 1 { hasConnector = true }
            }
            for instruction in leg.instructions {
                instructions.append(RouteInstruction(id: instructions.count, text: instruction.text, endDistance: distance + instruction.endDistance))
            }
            distance += leg.track.length
            if !legChoices.isEmpty {
                let choice = legChoices[ids[index]] ?? RouteLegChoice(mode: mode, speedMPH: mode.clampedSpeedMPH(defaultSpeedMPH ?? mode.defaultSpeedMPH))
                sections.append(RouteTravelSection(id: ids[index], startMetres: sectionStart, endMetres: distance,
                    mode: choice.mode, speedMPH: choice.mode.clampedSpeedMPH(choice.speedMPH)))
            }
            points += leg.coordinates
            if index < stops.count {
                pauses.append(RouteStop(id: stops[index].id, name: stops[index].name, metres: distance, waitSeconds: stops[index].waitSeconds))
            }
        }
        guard let track = RouteTrack(points.map(RoutePoint.init)) else { throw MissingRoute() }
        let actualLegs = legs.compactMap { $0 }
        guard let firstLeg = actualLegs.first else { throw MissingRoute() }
        let source: RoutePathSource = actualLegs.allSatisfy({ $0.source == firstLeg.source }) ? firstLeg.source
            : (sections.contains(where: { $0.mode == .drive }) ? .mixedModes : .mixedCyclingWalking)
        if !sections.isEmpty { sections[sections.count - 1].endMetres = track.length }
        let boundedStops = pauses.map { RouteStop(id: $0.id, name: $0.name, metres: min(track.length, $0.metres), waitSeconds: $0.waitSeconds) }
        var notices = Array(Set(actualLegs.flatMap(\.notices))).sorted()
        if !sections.isEmpty { notices.append("Optional section settings are on. Each section uses its own travel mode, speed, and matching directions.") }
        if hasConnector { notices.append("Short links of at most 25 metres join directions at stops.") }
        return [PlannedRoute(name: stops.isEmpty ? end.name : "\(stops.count) stops to \(end.name)", origin: start, destination: end,
            coordinates: track.points.map(\.coordinate), track: track, source: source, distance: track.length,
            notices: notices, appleTravelTime: nil, instructions: instructions, calculatedAt: Date(), stops: boundedStops, travelSections: sections)]
    }

    static func mapRoutes(
        from start: RoutePlace,
        to end: RoutePlace,
        mode: TravelMode,
        preferWalkingPaths: Bool = false
    ) async throws -> [PlannedRoute] {
        if mode.routeNetwork == .cycling, preferWalkingPaths {
            return try await requestRoutes(from: start, to: end, network: .walking, source: .walkingForCycling(fallback: false))
        }
        do {
            return try await requestRoutes(from: start, to: end, network: mode.routeNetwork, source: .apple(mode.routeNetwork))
        } catch {
            try Task.checkCancellation()
            let nsError = error as NSError
            let missing = error is MissingRoute || (nsError.domain == MKErrorDomain && nsError.code == MKError.Code.directionsNotFound.rawValue)
            guard mode.routeNetwork == .cycling, missing else { throw error }
            return try await requestRoutes(from: start, to: end, network: .walking, source: .walkingForCycling(fallback: true))
        }
    }

    private struct MissingRoute: LocalizedError {
        var errorDescription: String? { "No matching path was found. Try other endpoints or draw your own route." }
    }

    private static func requestRoutes(from start: RoutePlace, to end: RoutePlace,
                                      network: RouteNetwork, source: RoutePathSource) async throws -> [PlannedRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end.coordinate))
        switch network {
        case .walking: request.transportType = .walking
        case .cycling: request.transportType = .cycling
        case .driving: request.transportType = .automobile
        }
        request.requestsAlternateRoutes = true
        request.departureDate = Date()

        let directions = MKDirections(request: request)
        let response = try await directions.calculate()
        try Task.checkCancellation()
        let matches = response.routes.filter { $0.transportType == request.transportType }
        guard !matches.isEmpty else { throw MissingRoute() }
        let plans = matches.prefix(3).compactMap { route -> PlannedRoute? in
            let coordinates = sample(polyline: route.polyline, every: 12)
            guard let track = RouteTrack(coordinates.map(RoutePoint.init)) else { return nil }
            let metres = track.length
            let steps = route.steps.filter { !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let stepTotal = steps.reduce(0.0) { $0 + max(0, $1.distance) }
            var cumulative = 0.0
            let instructions = steps.enumerated().map { index, step -> RouteInstruction in
                cumulative += max(0, step.distance)
                return RouteInstruction(id: index, text: step.instructions,
                    endDistance: stepTotal > 0 ? metres * cumulative / stepTotal : metres)
            }
            return PlannedRoute(name: route.name.isEmpty ? network.title : route.name,
                                origin: start, destination: end, coordinates: coordinates,
                                track: track, source: source, distance: metres, notices: route.advisoryNotices,
                                appleTravelTime: route.expectedTravelTime > 0 ? route.expectedTravelTime : nil,
                                instructions: instructions, calculatedAt: Date())
        }
        guard !plans.isEmpty else { throw MissingRoute() }
        return plans
    }

    static func distance(of coordinates: [CLLocationCoordinate2D]) -> Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0.0) { total, pair in
            total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }

    static func customRoute(_ coordinates: [CLLocationCoordinate2D], source: RoutePathSource) -> PlannedRoute? {
        guard coordinates.count > 1, coordinates.allSatisfy({ CLLocationCoordinate2DIsValid($0) }),
              let first = coordinates.first, let last = coordinates.last else { return nil }
        let points = sample(coordinates: coordinates, every: 10)
        guard let track = RouteTrack(points.map(RoutePoint.init)) else { return nil }
        let metres = track.length
        return PlannedRoute(name: source.title, origin: RoutePlace(name: "Path start", coordinate: first),
                            destination: RoutePlace(name: "Path end", coordinate: last), coordinates: points,
                            track: track, source: source, distance: metres, notices: [], appleTravelTime: nil,
                            instructions: [RouteInstruction(id: 0, text: "Follow the supplied path", endDistance: metres)],
                            calculatedAt: Date())
    }

    static func sample(polyline: MKPolyline, every meters: CLLocationDistance) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return sample(coordinates: coords, every: meters)
    }

    static func sample(coordinates: [CLLocationCoordinate2D], every meters: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 1 else { return coordinates }
        guard coordinates.allSatisfy({ CLLocationCoordinate2DIsValid($0) }), meters.isFinite, meters > 0 else { return [] }
        let spacing = max(meters, distance(of: coordinates) / 50_000)
        var sampled = [coordinates[0]]
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            let dist = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            let steps = max(1, Int(ceil(dist / spacing)))
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                sampled.append(RoutePoint(a).interpolated(to: RoutePoint(b), fraction: t).coordinate)
            }
        }
        return sampled
    }
}

extension RoutePoint {
    init(_ coordinate: CLLocationCoordinate2D) { self.init(latitude: coordinate.latitude, longitude: coordinate.longitude) }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

enum GPXCodec {
    static func parse(_ url: URL) throws -> [CLLocationCoordinate2D] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        var coords: [CLLocationCoordinate2D] = []
        let pattern = #"lat="([^"]+)"[^>]*lon="([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let latR = Range(match.range(at: 1), in: text),
                  let lonR = Range(match.range(at: 2), in: text),
                  let lat = Double(text[latR]),
                  let lon = Double(text[lonR]) else { return }
            coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        // Also support lon before lat
        if coords.isEmpty {
            let alt = #"lon="([^"]+)"[^>]*lat="([^"]+)""#
            let altRegex = try NSRegularExpression(pattern: alt)
            altRegex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match,
                      let lonR = Range(match.range(at: 1), in: text),
                      let latR = Range(match.range(at: 2), in: text),
                      let lon = Double(text[lonR]),
                      let lat = Double(text[latR]) else { return }
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
        guard !coords.isEmpty else {
            throw NSError(domain: "Locus", code: 2, userInfo: [NSLocalizedDescriptionKey: "No track points found in GPX"])
        }
        return coords
    }

    static func export(_ coordinates: [CLLocationCoordinate2D], name: String = "Shift Route") -> String {
        let escapedName = name.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        var body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Shift" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(escapedName)</name>
            <trkseg>

        """
        for c in coordinates {
            body += String(format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\"></trkpt>\n", c.latitude, c.longitude)
        }
        body += """
            </trkseg>
          </trk>
        </gpx>
        """
        return body
    }
}
