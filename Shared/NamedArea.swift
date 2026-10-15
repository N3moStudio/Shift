import Foundation

enum PlaceLabel {
    static func isCoordinate(_ text: String) -> Bool {
        let parts = text.split(separator: ",")
        return parts.count == 2 && parts.allSatisfy { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) != nil }
    }
    static func readable(_ text: String, fallback: String = "Saved place") -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || isCoordinate(value) ? fallback : value
    }
}

/// Local display labels, never a location-monitoring or location-write service.
struct NamedArea: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var points: [RoutePoint]

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120 &&
        (3...200).contains(points.count) && points.allSatisfy(\.isValid) &&
        Set(points.map { "\($0.latitude),\($0.longitude)" }).count == points.count && area > 0.000000000001 && !hasCrossingEdges
    }

    // Unwrap around the first vertex so a small area can cross the date line.
    private func x(_ longitude: Double) -> Double {
        guard let first = points.first else { return longitude }
        let delta = longitude - first.longitude
        return delta - 360 * floor((delta + 180) / 360)
    }
    var area: Double {
        guard points.count >= 3 else { return 0 }
        return abs(points.indices.reduce(0.0) { sum, i in
            let a = points[i], b = points[(i + 1) % points.count]
            return sum + x(a.longitude) * b.latitude - x(b.longitude) * a.latitude
        }) / 2
    }
    private var hasCrossingEdges: Bool {
        guard points.count >= 4 else { return false }
        func turn(_ a: RoutePoint, _ b: RoutePoint, _ c: RoutePoint) -> Double {
            (x(b.longitude) - x(a.longitude)) * (c.latitude - a.latitude) -
            (b.latitude - a.latitude) * (x(c.longitude) - x(a.longitude))
        }
        for i in points.indices {
            for j in (i + 1)..<points.count {
                if j == i + 1 || (i == 0 && j == points.count - 1) { continue }
                let a = points[i], b = points[(i + 1) % points.count]
                let c = points[j], d = points[(j + 1) % points.count]
                if turn(a, b, c) * turn(a, b, d) < 0 && turn(c, d, a) * turn(c, d, b) < 0 { return true }
            }
        }
        return false
    }
    func contains(_ point: RoutePoint) -> Bool {
        guard point.isValid, points.count >= 3 else { return false }
        let px = x(point.longitude), py = point.latitude
        var inside = false
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            let ax = x(a.longitude), bx = x(b.longitude)
            let cross = (px - ax) * (b.latitude - a.latitude) - (py - a.latitude) * (bx - ax)
            if abs(cross) < 1e-12 && px >= min(ax, bx) && px <= max(ax, bx) &&
                py >= min(a.latitude, b.latitude) && py <= max(a.latitude, b.latitude) { return true }
            if (a.latitude > py) != (b.latitude > py),
               px < (bx - ax) * (py - a.latitude) / (b.latitude - a.latitude) + ax { inside.toggle() }
        }
        return inside
    }
    static func name(at point: RoutePoint, in areas: [NamedArea]) -> String? {
        // Smallest containing area wins; array order breaks ties deterministically.
        areas.filter { $0.contains(point) }.enumerated().min {
            $0.element.area == $1.element.area ? $0.offset < $1.offset : $0.element.area < $1.element.area
        }?.element.name
    }
}
