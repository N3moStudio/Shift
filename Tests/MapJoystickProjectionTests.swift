import XCTest
@testable import SessionPresentation

final class MapJoystickProjectionTests: XCTestCase {
    func testDownFollowsAllFourMapOrientations() {
        for (heading, east, north) in [(0.0, 0.0, -1.0), (90, -1, 0), (180, 0, 1), (270, 1, 0)] {
            let vector = MapJoystickProjection.vector(right: 0, down: 1, heading: heading)
            XCTAssertEqual(vector.east, east, accuracy: 0.000001)
            XCTAssertEqual(vector.north, north, accuracy: 0.000001)
        }
    }

    func testRightAndDiagonalsStayAlignedWithTheScreen() {
        for heading in stride(from: -360.0, through: 720.0, by: 15) {
            for (right, down) in [(1.0, 0.0), (-0.4, 0.7), (0.3, -0.2), (0, 0)] {
                let vector = MapJoystickProjection.vector(right: right, down: down, heading: heading)
                // Project the geographic movement back onto the visible map.
                let angle = heading * .pi / 180
                let screenRight = vector.east * cos(angle) - vector.north * sin(angle)
                let screenDown = -vector.east * sin(angle) - vector.north * cos(angle)
                XCTAssertEqual(screenRight, right, accuracy: 0.000001)
                XCTAssertEqual(screenDown, down, accuracy: 0.000001)
                XCTAssertEqual(hypot(vector.east, vector.north), hypot(right, down), accuracy: 0.000001)
            }
        }
    }

    func testRotatingWhileHoldingStickUsesTheNewHeading() {
        let before = MapJoystickProjection.vector(right: 0, down: -0.5, heading: 0)
        let after = MapJoystickProjection.vector(right: 0, down: -0.5, heading: 90)
        XCTAssertEqual(before.north, 0.5, accuracy: 0.000001)
        XCTAssertEqual(after.east, 0.5, accuracy: 0.000001)
        XCTAssertEqual(after.north, 0, accuracy: 0.000001)
    }

    func testInvalidInputCannotProduceMovement() {
        for (right, down, heading) in [(Double.nan, 1.0, 0.0), (1, .infinity, 0), (1, 1, .nan)] {
            let vector = MapJoystickProjection.vector(right: right, down: down, heading: heading)
            XCTAssertEqual(vector.east, 0)
            XCTAssertEqual(vector.north, 0)
        }
    }
}
