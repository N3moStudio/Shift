import Foundation

enum DrawnPathEdit {
    /// Waits and section boundaries keep their relative position on the edited
    /// path. The editor explicitly asks users to review these before starting.
    static func replacing(_ original: SavedTrip, with points: [RoutePoint]) -> SavedTrip? {
        guard original.source == .drawn, original.isValid, points.count <= RouteDrawing.pointLimit,
              let old = RouteTrack(original.points), let new = RouteTrack(points) else { return nil }
        let scale = new.length / old.length
        var result = original
        result.points = new.points
        result.stops = original.stops.map { stop in
            var copy = stop; copy.metres = min(new.length, stop.metres * scale); return copy
        }
        result.travelSections = original.travelSections?.map { section in
            var copy = section
            copy.startMetres = section.startMetres * scale
            copy.endMetres = min(new.length, section.endMetres * scale)
            return copy
        }
        // Old turn instructions no longer describe edited geometry.
        result.instructions = []
        result.calculatedAt = Date()
        result.savedAt = Date()
        return result.isValid ? result : nil
    }
}

struct PointEditHistory {
    private(set) var points: [RoutePoint]
    private var past: [[RoutePoint]] = []
    private var future: [[RoutePoint]] = []
    private var dragStart: [RoutePoint]?
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    init(_ points: [RoutePoint]) { self.points = points }
    mutating func replace(_ next: [RoutePoint]) {
        guard next != points, next.count <= RouteDrawing.pointLimit, next.allSatisfy(\.isValid) else { return }
        remember(points); points = next
    }
    mutating func move(_ index: Int, to point: RoutePoint) {
        guard points.indices.contains(index), point.isValid else { return }
        if dragStart == nil { dragStart = points }
        points[index] = point
    }
    mutating func endDrag(cancelled: Bool) {
        guard let start = dragStart else { return }
        if cancelled { points = start } else if points != start { remember(start) }
        dragStart = nil
    }
    mutating func undo() {
        endDrag(cancelled: false)
        guard let last = past.popLast() else { return }; future.append(points); points = last
    }
    mutating func redo() {
        endDrag(cancelled: false)
        guard let next = future.popLast() else { return }; past.append(points); points = next
    }
    private mutating func remember(_ value: [RoutePoint]) {
        past.append(value); if past.count > 40 { past.removeFirst() }; future = []
    }
}
