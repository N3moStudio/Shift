import XCTest
@testable import SessionPresentation

final class PrecisionControlsTests: XCTestCase {
    func testWriteLatencyUsesRemainingTickTimeInsteadOfAnotherFullDelay() {
        var clock = RoutePlaybackClock(now: 0)
        XCTAssertEqual(clock.delay(now: 0), 0.5)
        XCTAssertEqual(clock.advance(now: 0.5), 0.5)
        // A write took 0.2 seconds. The next wait must be only 0.3 seconds.
        XCTAssertEqual(clock.delay(now: 0.7), 0.3, accuracy: 0.000001)
        XCTAssertEqual(clock.advance(now: 1), 0.5)
    }

    func testConstantCruiseCoversTheRequestedDistanceDespiteShortCommandDelays() {
        var clock = RoutePlaybackClock(now: 0)
        var now = 0.0, metres = 0.0
        for _ in 0..<120 {
            now += clock.delay(now: now)
            let elapsed = clock.advance(now: now)
            metres += RouteMotion.step(speed: 10, target: 10, remaining: 10_000,
                                       mode: .eBike, smooth: false, seconds: elapsed).metres
            now += 0.2
        }
        XCTAssertEqual(metres, 600, accuracy: 0.00001)
        XCTAssertEqual(now, 60.2, accuracy: 0.00001)
    }

    func testSlowOrdinaryWriteCountsButSuspensionDoesNotCatchUp() {
        var clock = RoutePlaybackClock(now: 0)
        XCTAssertEqual(clock.advance(now: 0.8), 0.8)
        XCTAssertEqual(RouteMotion.step(speed: 10, target: 10, remaining: 100,
                                       mode: .eBike, smooth: false, seconds: 0.8).metres, 8)
        XCTAssertEqual(clock.advance(now: 300), 0.5)
        clock.reset(now: 600)
        XCTAssertEqual(clock.advance(now: 600.5), 0.5)
    }

    func testLiveSpeedChangeUsesNewTargetAndRespectsSmoothOption() {
        let instant = RouteMotion.step(speed: 2, target: 12, remaining: 1000, mode: .eBike, smooth: false)
        XCTAssertEqual(instant.speed, 12)
        XCTAssertEqual(instant.metres, 6)
        let smooth = RouteMotion.step(speed: 2, target: 12, remaining: 1000, mode: .eBike, smooth: true)
        XCTAssertLessThan(smooth.speed, 12)
        XCTAssertGreaterThan(smooth.speed, 2)
        let slower = RouteMotion.step(speed: 12, target: 2, remaining: 1000, mode: .eBike, smooth: false)
        XCTAssertEqual(slower.metres, 1)
    }

    func testDisplayedSpeedMeasuresConfirmedDistanceOverRealElapsedTime() {
        var samples = RouteSpeedSamples()
        samples.append(metres: 5, seconds: 0.7)
        XCTAssertEqual(samples.metresPerSecond, 5 / 0.7, accuracy: 0.00001)
        samples.append(metres: 5, seconds: 0.5)
        XCTAssertEqual(samples.metresPerSecond, 10 / 1.2, accuracy: 0.00001)
        samples.reset()
        XCTAssertEqual(samples.metresPerSecond, 0)
    }

    func testMarkerAndPolylineUseTheSameProjectionAtHigherLatitudes() throws {
        let a = RoutePoint(latitude: 60, longitude: 10)
        let b = RoutePoint(latitude: 65, longitude: 20)
        let track = try XCTUnwrap(RouteTrack([a, b]))
        let mid = track.point(at: track.length / 2)
        XCTAssertEqual(mid.mercatorY, (a.mercatorY + b.mercatorY) / 2, accuracy: 0.0000001)
        let nearest = try XCTUnwrap(track.nearest(to: mid))
        XCTAssertEqual(nearest.metres, track.length / 2, accuracy: 0.001)
        XCTAssertEqual(nearest.point.latitude, mid.latitude, accuracy: 0.0000001)
    }

    func testMarkerStaysOnSegmentsAroundBothSidesOfACorner() throws {
        let a = RoutePoint(latitude: 37, longitude: -122)
        let b = RoutePoint(latitude: 37, longitude: -121.99)
        let c = RoutePoint(latitude: 37.01, longitude: -121.99)
        let track = try XCTUnwrap(RouteTrack([a, b, c]))
        for distance in stride(from: track.cumulative[1] - 20, through: track.cumulative[1] + 20, by: 1) {
            let point = track.point(at: distance)
            let snap = try XCTUnwrap(track.nearest(to: point, preferredDistance: distance))
            XCTAssertEqual(snap.metres, distance, accuracy: 0.01)
            XCTAssertLessThan(snap.point.distance(to: point), 0.01)
        }
    }

    func testDragToleranceRetainsNearbyBranchUntilFingerClearlyMovesAway() throws {
        let track = try XCTUnwrap(RouteTrack([
            RoutePoint(latitude: 0, longitude: 0), RoutePoint(latitude: 0, longitude: 0.01),
            RoutePoint(latitude: 0.00005, longitude: 0.01), RoutePoint(latitude: 0.00005, longitude: 0)
        ]))
        let nearby = RoutePoint(latitude: 0.00003, longitude: 0.005)
        let exact = try XCTUnwrap(track.nearest(to: nearby))
        let stable = try XCTUnwrap(track.nearest(to: nearby, preferredDistance: track.cumulative[1] / 2,
                                               continuityTolerance: 2))
        XCTAssertGreaterThan(exact.metres, track.cumulative[2])
        XCTAssertLessThan(stable.metres, track.cumulative[1])
        let switched = try XCTUnwrap(track.nearest(to: RoutePoint(latitude: 0.00005, longitude: 0.005),
                                                  preferredDistance: stable.metres, continuityTolerance: 2))
        XCTAssertGreaterThan(switched.metres, track.cumulative[2])
    }

    func testDetailedDrawingRetainsSmallDeliberateMoves() {
        var drawing = RouteDrawing()
        drawing.beginStroke()
        drawing.append(RoutePoint(latitude: 0, longitude: 0), spacing: 0.05)
        drawing.append(RoutePoint(latitude: 0, longitude: 0.000005), spacing: 0.05)
        drawing.endStroke()
        XCTAssertEqual(drawing.points.count, 2)
        drawing.undo()
        XCTAssertTrue(drawing.points.isEmpty)
    }

    func testDisplayPreferencesAreIndependentAndOldActivitiesStillDecode() throws {
        let now = Date()
        var state = SessionSnapshot(phase: .active, startedAt: now, lastConfirmedAt: now,
                                    expiresAt: now.addingTimeInterval(12), place: nil, lowPower: false,
                                    journey: JourneyActivity(state: .moving, progress: 0.2, remainingMetres: 100,
                                                             estimatedArrival: now.addingTimeInterval(10)))
        state.islandPlace = "Selected place"
        state.lockScreenShowsProgress = false
        state.islandShowsProgress = true
        state.islandShowsTimer = false
        XCTAssertNil(state.place)
        XCTAssertNotNil(state.islandPlace)
        XCTAssertNil(state.visibleJourney(onIsland: false, at: now))
        XCTAssertNotNil(state.visibleJourney(onIsland: true, at: now))
        XCTAssertNil(state.visibleJourney(onIsland: true, at: now.addingTimeInterval(13)))
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(SessionSnapshot.self, from: data), state)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["islandPlace", "lockScreenShowsProgress", "islandShowsProgress", "islandShowsTimer"] { old.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(restored.islandPlace)
        XCTAssertNotNil(restored.visibleJourney(onIsland: false, at: now))
        XCTAssertLessThan(data.count, 4096)
    }
}
