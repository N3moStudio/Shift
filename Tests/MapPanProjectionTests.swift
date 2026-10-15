import XCTest
@testable import SessionPresentation

final class MapPanProjectionTests: XCTestCase {
    func testNoCameraMutationForStationaryOrInvalidTouches() {
        XCTAssertNil(MapPanProjection.target(centerX: 200, centerY: 420, deltaX: 0, deltaY: 0))
        XCTAssertNil(MapPanProjection.target(centerX: 200, centerY: 420, deltaX: .nan, deltaY: 5))
    }

    func testInsetViewportHasNoCumulativeVerticalDrift() {
        // A camera center 60pt below the geometric midpoint, as with insets.
        // Inverse projection maps each screen-point difference into world units.
        var worldY = 1000.0
        for _ in 0..<100 {
            let target = MapPanProjection.target(centerX: 200, centerY: 460, deltaX: 2, deltaY: 0)!
            worldY += target.y - 460
        }
        XCTAssertEqual(worldY, 1000, accuracy: 0.00001)
    }

    func testDragOutAndBackRestoresCameraWithOffsetProjection() {
        var x = 1000.0, y = 2000.0
        for delta in [(20.0, 15.0), (-20.0, -15.0)] {
            let target = MapPanProjection.target(centerX: 180, centerY: 460, deltaX: delta.0, deltaY: delta.1)!
            x += target.x - 180; y += target.y - 460
        }
        XCTAssertEqual(x, 1000); XCTAssertEqual(y, 2000)
    }
}
