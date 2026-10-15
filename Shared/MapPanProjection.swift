import Foundation

/// Translate the projected camera center, not the geometric view midpoint.
/// MapKit can offset its projection for safe areas and layout margins.
enum MapPanProjection {
    static func target(centerX: Double, centerY: Double, deltaX: Double, deltaY: Double) -> (x: Double, y: Double)? {
        guard centerX.isFinite, centerY.isFinite, deltaX.isFinite, deltaY.isFinite,
              deltaX != 0 || deltaY != 0 else { return nil }
        return (centerX - deltaX, centerY - deltaY)
    }
}

/// Screen right/down -> geographic east/north for a flat, rotated map.
/// A heading of 90 degrees puts east at the top of the screen.
enum MapJoystickProjection {
    static func vector(right: Double, down: Double, heading: Double) -> (east: Double, north: Double) {
        guard right.isFinite, down.isFinite, heading.isFinite else { return (0, 0) }
        let angle = heading.truncatingRemainder(dividingBy: 360) * .pi / 180
        return (right * cos(angle) - down * sin(angle),
                -right * sin(angle) - down * cos(angle))
    }
}
