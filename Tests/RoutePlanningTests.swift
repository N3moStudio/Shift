import XCTest
@testable import SessionPresentation

final class RoutePlanningTests: XCTestCase {
    func testBothBikeModesPreferCyclingAndRejectUnlabeledAlternatePaths() {
        for mode in [TravelMode.cycle, .eBike] {
            XCTAssertEqual(mode.routeNetwork, .cycling)
            XCTAssertFalse(RoutePathSource.apple(.driving).supports(mode))
            XCTAssertFalse(RoutePathSource.apple(.walking).supports(mode))
            XCTAssertTrue(RoutePathSource.apple(.cycling).supports(mode))
        }
        XCTAssertEqual(TravelMode.drive.routeNetwork, .driving)
        XCTAssertEqual(TravelMode.run.routeNetwork, .walking)
    }

    func testExactUserPathsSurviveModeChanges() {
        for mode in TravelMode.allCases {
            XCTAssertTrue(RoutePathSource.drawn.supports(mode))
            XCTAssertTrue(RoutePathSource.gpx.supports(mode))
        }
        XCTAssertFalse(RoutePathSource.gpx.isAutomatic)
        XCTAssertTrue(RoutePathSource.apple(.cycling).isAutomatic)
    }

    func testOneToThirtyFiveMPHAndInvalidSavedSpeed() {
        XCTAssertEqual(EBikeSpeed.metresPerSecond(1), 0.44704, accuracy: 0.000001)
        XCTAssertEqual(EBikeSpeed.metresPerSecond(35), 15.6464, accuracy: 0.000001)
        XCTAssertEqual(EBikeSpeed.clamped(0), 1)
        XCTAssertEqual(EBikeSpeed.clamped(100), 35)
        XCTAssertEqual(EBikeSpeed.clamped(.nan), EBikeSpeed.defaultMPH)
        XCTAssertEqual(EBikeSpeed.clamped(.infinity), EBikeSpeed.defaultMPH)
    }

    func testPlaybackUsesRequestedPaceAndPreservesEndpoint() throws {
        for mph in [1.0, 20.0, 35.0] {
            let speed = EBikeSpeed.metresPerSecond(mph)
            var remaining = 17.123
            var elapsed = 0.0
            var iterations = 0
            while remaining > 0 {
                let step = try XCTUnwrap(RouteMovement.step(remainingMetres: remaining, metresPerSecond: speed))
                XCTAssertLessThanOrEqual(step.seconds, 0.5)
                XCTAssertLessThanOrEqual(step.metres, remaining)
                remaining = max(0, remaining - step.metres)
                elapsed += step.seconds
                iterations += 1
                XCTAssertLessThan(iterations, 1000)
                if iterations >= 1000 { break }
            }
            XCTAssertEqual(elapsed, 17.123 / speed, accuracy: 0.000001)
        }
    }

    func testSpeedChangesApplyToNextStepWithoutExceedingNewSpeed() throws {
        let fast = try XCTUnwrap(RouteMovement.step(remainingMetres: 100, metresPerSecond: EBikeSpeed.metresPerSecond(35)))
        let slow = try XCTUnwrap(RouteMovement.step(remainingMetres: 100 - fast.metres, metresPerSecond: EBikeSpeed.metresPerSecond(1)))
        XCTAssertEqual(slow.metres / slow.seconds, 0.44704, accuracy: 0.000001)
        XCTAssertLessThan(slow.metres, fast.metres)
    }

    func testInvalidOrFinishedSegmentsCannotScheduleMovement() {
        XCTAssertNil(RouteMovement.step(remainingMetres: 0, metresPerSecond: 1))
        XCTAssertNil(RouteMovement.step(remainingMetres: .nan, metresPerSecond: 1))
        XCTAssertNil(RouteMovement.step(remainingMetres: 10, metresPerSecond: 0))
        XCTAssertNil(RouteMovement.step(remainingMetres: 10, metresPerSecond: .infinity))
    }
}
