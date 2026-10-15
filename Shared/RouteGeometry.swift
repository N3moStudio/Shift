import Foundation

struct RoutePoint: Equatable, Codable {
    let latitude: Double
    let longitude: Double
    var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }

    static func longitudeDelta(_ value: Double) -> Double {
        var result = value.truncatingRemainder(dividingBy: 360)
        if result > 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }
    func distance(to other: RoutePoint) -> Double {
        let a = latitude * .pi / 180, b = other.latitude * .pi / 180
        let d = (b - a) / 2, l = Self.longitudeDelta(other.longitude - longitude) * .pi / 360
        let h = min(1, max(0, sin(d) * sin(d) + cos(a) * cos(b) * sin(l) * sin(l)))
        return 6_371_000 * 2 * atan2(sqrt(h), sqrt(1 - h))
    }
    func interpolated(to other: RoutePoint, fraction: Double) -> RoutePoint {
        let t = min(1, max(0, fraction))
        if t == 0 { return self }
        if t == 1 { return other }
        // MapKit draws polyline segments in Mercator space. Use that same
        // line for the distance cursor, marker, and nearest-point calculation.
        let y = mercatorY + (other.mercatorY - mercatorY) * t
        return RoutePoint(latitude: atan(sinh(y)) * 180 / .pi,
                          longitude: Self.longitudeDelta(longitude + Self.longitudeDelta(other.longitude - longitude) * t))
    }
    var mercatorY: Double {
        let radians = min(85.05112878, max(-85.05112878, latitude)) * .pi / 180
        return log(tan(.pi / 4 + radians / 2))
    }
}

struct RouteTrack {
    let points: [RoutePoint]
    let cumulative: [Double]
    private let projectedY: [Double]
    var length: Double { cumulative.last ?? 0 }

    init?(_ input: [RoutePoint]) {
        guard input.count > 1, input.allSatisfy(\.isValid) else { return nil }
        var clean: [RoutePoint] = [], distances: [Double] = []
        for point in input {
            if let previous = clean.last {
                let distance = previous.distance(to: point)
                if distance < 0.001 { continue }
                distances.append((distances.last ?? 0) + distance)
            } else { distances.append(0) }
            clean.append(point)
        }
        guard clean.count > 1, let length = distances.last, length.isFinite, length > 0 else { return nil }
        points = clean
        cumulative = distances
        projectedY = clean.map(\.mercatorY)
    }

    func point(at metres: Double) -> RoutePoint {
        let target = metres.isFinite ? min(length, max(0, metres)) : 0
        if target <= 0 { return points[0] }
        if target >= length { return points[points.count - 1] }
        var low = 1, high = cumulative.count - 1
        while low < high {
            let mid = (low + high) / 2
            if cumulative[mid] < target { low = mid + 1 } else { high = mid }
        }
        let start = cumulative[low - 1], span = cumulative[low] - start
        return points[low - 1].interpolated(to: points[low], fraction: (target - start) / span)
    }

    func nearest(to query: RoutePoint, preferredDistance: Double = 0,
                 continuityTolerance: Double = 0) -> (metres: Double, point: RoutePoint)? {
        guard query.isValid else { return nil }
        let queryY = query.mercatorY
        let metresPerRadian = 6_371_000 * max(0.000001, cos(query.latitude * .pi / 180))
        func candidate(_ index: Int) -> (metres: Double, distance: Double) {
            let a = points[index - 1], b = points[index]
            let dx = RoutePoint.longitudeDelta(b.longitude - a.longitude) * .pi / 180
            let dy = projectedY[index] - projectedY[index - 1]
            let qx = RoutePoint.longitudeDelta(query.longitude - a.longitude) * .pi / 180
            let qy = queryY - projectedY[index - 1]
            let denominator = dx * dx + dy * dy
            let t = denominator > 0 ? min(1, max(0, (qx * dx + qy * dy) / denominator)) : 0
            let metres = cumulative[index - 1] + (cumulative[index] - cumulative[index - 1]) * t
            return (metres, hypot(qx - dx * t, qy - dy * t) * metresPerRadian)
        }
        var bestMetres = 0.0, bestDistance = Double.infinity
        for index in 1..<points.count {
            let (metres, distance) = candidate(index)
            if distance < bestDistance - 0.05 || (abs(distance - bestDistance) <= 0.05 && abs(metres - preferredDistance) < abs(bestMetres - preferredDistance)) {
                bestDistance = distance
                bestMetres = metres
            }
        }
        // A tiny screen-derived tolerance keeps a drag on its current branch
        // at intersections. Move clearly onto the other branch to select it.
        if continuityTolerance.isFinite, continuityTolerance > 0 {
            let limit = bestDistance + continuityTolerance
            for index in 1..<points.count {
                let (metres, distance) = candidate(index)
                if distance <= limit, abs(metres - preferredDistance) < abs(bestMetres - preferredDistance) {
                    bestMetres = metres
                }
            }
        }
        return (bestMetres, point(at: bestMetres))
    }
}

/// A cached Mercator index supplies the nearest segment without rescanning a
/// long route on every finger movement. The map refines these candidates in
/// its own screen coordinates before selecting an exact distance cursor.
struct RouteSnapIndex {
    private struct Segment {
        let index: Int
        let x: Double, y: Double, dx: Double, dy: Double
        let startMetres: Double, length: Double
        var minX: Double { min(x, x + dx) }
        var maxX: Double { max(x, x + dx) }
        var minY: Double { min(y, y + dy) }
        var maxY: Double { max(y, y + dy) }
    }
    private struct Node {
        var minX: Double, minY: Double, maxX: Double, maxY: Double
        var lower: Int, upper: Int
        var left = -1, right = -1
        func distanceSquared(x: Double, y: Double) -> Double {
            let dx = max(minX - x, max(0, x - maxX))
            let dy = max(minY - y, max(0, y - maxY))
            return dx * dx + dy * dy
        }
    }
    private let segments: [Segment]
    private let order: [Int]
    private let nodes: [Node]
    private let cumulative: [Double]

    init(track: RouteTrack) {
        let segments = (1..<track.points.count).map { index in
            let a = track.points[index - 1], b = track.points[index]
            return Segment(index: index, x: a.longitude * .pi / 180, y: a.mercatorY,
                dx: RoutePoint.longitudeDelta(b.longitude - a.longitude) * .pi / 180,
                dy: b.mercatorY - a.mercatorY, startMetres: track.cumulative[index - 1],
                length: track.cumulative[index] - track.cumulative[index - 1])
        }
        var order = Array(segments.indices)
        var nodes: [Node] = []
        func build(_ lower: Int, _ upper: Int) -> Int {
            let first = segments[order[lower]]
            var node = Node(minX: first.minX, minY: first.minY, maxX: first.maxX, maxY: first.maxY,
                            lower: lower, upper: upper)
            for offset in (lower + 1)..<upper {
                let segment = segments[order[offset]]
                node.minX = min(node.minX, segment.minX); node.maxX = max(node.maxX, segment.maxX)
                node.minY = min(node.minY, segment.minY); node.maxY = max(node.maxY, segment.maxY)
            }
            let index = nodes.count
            nodes.append(node)
            if upper - lower > 8 {
                let horizontal = node.maxX - node.minX >= node.maxY - node.minY
                let sorted = order[lower..<upper].sorted {
                    let a = segments[$0], b = segments[$1]
                    return horizontal ? (a.minX + a.maxX < b.minX + b.maxX) : (a.minY + a.maxY < b.minY + b.maxY)
                }
                order.replaceSubrange(lower..<upper, with: sorted)
                let middle = (lower + upper) / 2
                node.left = build(lower, middle)
                node.right = build(middle, upper)
                nodes[index] = node
            }
            return index
        }
        _ = build(0, segments.count)
        self.segments = segments
        self.order = order
        self.nodes = nodes
        cumulative = track.cumulative
    }

    func nearest(to point: RoutePoint, preferredDistance: Double = 0) -> (metres: Double, segmentIndex: Int)? {
        guard point.isValid, !nodes.isEmpty else { return nil }
        let queryY = point.mercatorY
        var bestSquared = Double.infinity, bestMetres = 0.0, bestIndex = 1
        let tie = 1e-12
        func search(_ nodeIndex: Int, x: Double) {
            let node = nodes[nodeIndex]
            let radius = sqrt(bestSquared) + tie
            guard node.distanceSquared(x: x, y: queryY) <= radius * radius else { return }
            if node.left < 0 {
                for offset in node.lower..<node.upper {
                    let segment = segments[order[offset]]
                    let qx = x - segment.x, qy = queryY - segment.y
                    let denominator = segment.dx * segment.dx + segment.dy * segment.dy
                    let fraction = denominator > 0 ? min(1, max(0, (qx * segment.dx + qy * segment.dy) / denominator)) : 0
                    let dx = qx - segment.dx * fraction, dy = qy - segment.dy * fraction
                    let squared = dx * dx + dy * dy
                    let metres = segment.startMetres + segment.length * fraction
                    let distance = sqrt(squared), best = sqrt(bestSquared)
                    if distance < best - tie || (abs(distance - best) <= tie && abs(metres - preferredDistance) < abs(bestMetres - preferredDistance)) {
                        bestSquared = squared; bestMetres = metres; bestIndex = segment.index
                    }
                }
            } else {
                let left = nodes[node.left].distanceSquared(x: x, y: queryY)
                let right = nodes[node.right].distanceSquared(x: x, y: queryY)
                if left <= right { search(node.left, x: x); search(node.right, x: x) }
                else { search(node.right, x: x); search(node.left, x: x) }
            }
        }
        // Each segment follows the shortest longitude span. Check adjacent
        // world copies so routes crossing the date line remain continuous.
        let x = point.longitude * .pi / 180
        for shift in [-2 * Double.pi, 0, 2 * Double.pi] { search(0, x: x + shift) }
        return bestSquared.isFinite ? (bestMetres, bestIndex) : nil
    }

    func candidateSegments(near point: RoutePoint, preferredDistance: Double) -> [Int] {
        guard let nearest = nearest(to: point, preferredDistance: preferredDistance) else { return [] }
        var low = 1, high = cumulative.count - 1
        while low < high {
            let middle = (low + high) / 2
            if cumulative[middle] < preferredDistance { low = middle + 1 } else { high = middle }
        }
        return Set([nearest.segmentIndex - 1, nearest.segmentIndex, nearest.segmentIndex + 1, low - 1, low, low + 1])
            .filter { $0 > 0 && $0 < cumulative.count }.sorted()
    }
}

struct RouteScreenPoint: Equatable {
    let x: Double
    let y: Double
}

struct RouteScreenSegment {
    let start: RouteScreenPoint
    let end: RouteScreenPoint
    let startMetres: Double
    let endMetres: Double
}

struct RouteScreenSnap: Equatable {
    let metres: Double
    let point: RouteScreenPoint
    let distance: Double

    /// Map-projected endpoints are authoritative. Only subpixel ties prefer
    /// the prior branch; no multi-pixel allowance can hold a marker at a corner.
    static func closest(to query: RouteScreenPoint, segments: [RouteScreenSegment], preferredDistance: Double) -> Self? {
        guard query.x.isFinite, query.y.isFinite else { return nil }
        var best: Self?
        for segment in segments {
            guard segment.start.x.isFinite, segment.start.y.isFinite, segment.end.x.isFinite, segment.end.y.isFinite,
                  segment.startMetres.isFinite, segment.endMetres.isFinite, segment.endMetres > segment.startMetres else { continue }
            let dx = segment.end.x - segment.start.x, dy = segment.end.y - segment.start.y
            let qx = query.x - segment.start.x, qy = query.y - segment.start.y
            let denominator = dx * dx + dy * dy
            guard denominator > 0 else { continue }
            let fraction = min(1, max(0, (qx * dx + qy * dy) / denominator))
            let point = RouteScreenPoint(x: segment.start.x + fraction * dx, y: segment.start.y + fraction * dy)
            let candidate = Self(metres: segment.startMetres + fraction * (segment.endMetres - segment.startMetres),
                                 point: point, distance: hypot(query.x - point.x, query.y - point.y))
            if let current = best {
                if candidate.distance < current.distance - 0.25 ||
                    (abs(candidate.distance - current.distance) <= 0.25 && abs(candidate.metres - preferredDistance) < abs(current.metres - preferredDistance)) {
                    best = candidate
                }
            } else { best = candidate }
        }
        return best
    }
}

/// The same distance cursor drives normal playback and explicit forward/back seeks.
struct RouteSeek: Equatable {
    let routeID: UUID
    let metres: Double
    let expiresAt: Date
    func isValid(routeID current: UUID?, now: Date) -> Bool {
        routeID == current && metres.isFinite && metres >= 0 && now < expiresAt
    }
}

struct RouteDrawing {
    static let pointLimit = 5_000
    private(set) var points: [RoutePoint] = []
    private var undoFrames: [[RoutePoint]] = []
    private var redoFrames: [[RoutePoint]] = []
    private var strokeStart: [RoutePoint]?
    var canUndo: Bool { !undoFrames.isEmpty }
    var canRedo: Bool { !redoFrames.isEmpty }
    private(set) var distance: Double = 0

    mutating func replacePoints(_ edited: [RoutePoint]) {
        guard edited.count <= Self.pointLimit, edited.allSatisfy(\.isValid), edited != points else { return }
        endStroke(); remember(points); points = edited; updateDistance()
    }
    mutating func beginStroke() { if strokeStart == nil { strokeStart = points } }
    mutating func append(_ point: RoutePoint, spacing: Double = 2) {
        guard point.isValid, points.count < Self.pointLimit,
              points.last.map({ $0.distance(to: point) >= spacing }) ?? true else { return }
        if strokeStart == nil { remember(points) }
        if let previous = points.last { distance += previous.distance(to: point) }
        points.append(point)
    }
    mutating func endStroke() {
        if let before = strokeStart, before != points { remember(before) }
        strokeStart = nil
    }
    mutating func undo() {
        endStroke()
        guard let previous = undoFrames.popLast() else { return }
        redoFrames.append(points)
        points = previous
        updateDistance()
    }
    mutating func redo() {
        endStroke()
        guard let next = redoFrames.popLast() else { return }
        undoFrames.append(points)
        points = next
        updateDistance()
    }
    mutating func clear() {
        endStroke()
        guard !points.isEmpty else { return }
        remember(points)
        points = []
        distance = 0
    }
    private mutating func updateDistance() {
        distance = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }
    private mutating func remember(_ frame: [RoutePoint]) {
        undoFrames.append(frame)
        if undoFrames.count > 40 { undoFrames.removeFirst() }
        redoFrames = []
    }
}
